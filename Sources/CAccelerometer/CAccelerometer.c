#include "CAccelerometer.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum {
    pageVendor = 0xFF00,
    usageAccelerometer = 3,
    // Apple SPU accelerometer reports are 22 bytes; x/y/z int32 values start at byte 6.
    imuReportLength = 22,
    imuDataOffset = 6,
    imuDecimation = 8,
    reportBufferSize = 4096,
    reportIntervalMicroseconds = 1000,
    startupTimeoutSeconds = 10,
    maxDevices = 8
};

typedef struct {
    IOHIDDeviceRef device;
    uint8_t *reportBuffer;
} RegisteredDevice;

static NomasMotionAccelCallback g_callback = NULL;
static void *g_context = NULL;
static pthread_t g_thread;
static bool g_threadCreated = false;
static bool g_running = false;
static bool g_stopRequested = false;
static bool g_stopInProgress = false;
static pthread_t g_stopOwner;
static bool g_startupComplete = false;
static int g_startupStatus = NOMAS_ACCEL_OK;
static unsigned int g_callbacksInFlight = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_startupCond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_quiescentCond = PTHREAD_COND_INITIALIZER;
static RegisteredDevice g_devices[maxDevices];
static int g_deviceCount = 0;
static int g_decimationCounter = 0;
static const char *g_lastStage = "not started";

static bool stopRequested(void) {
    bool requested;
    pthread_mutex_lock(&g_lock);
    requested = g_stopRequested;
    pthread_mutex_unlock(&g_lock);
    return requested;
}

static void setStage(const char *stage) {
    pthread_mutex_lock(&g_lock);
    g_lastStage = stage;
    pthread_mutex_unlock(&g_lock);
}

static int32_t readInt32LE(const uint8_t *data) {
    uint32_t value = ((uint32_t)data[0])
        | ((uint32_t)data[1] << 8)
        | ((uint32_t)data[2] << 16)
        | ((uint32_t)data[3] << 24);
    return (int32_t)value;
}

static int64_t registryInt(io_service_t service, CFStringRef key, bool *ok) {
    *ok = false;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value == NULL) {
        return 0;
    }

    int64_t result = 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        *ok = CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &result);
    }
    CFRelease(value);
    return result;
}

static void setRegistryInt(io_service_t service, CFStringRef key, int32_t value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (number == NULL) {
        return;
    }
    IORegistryEntrySetCFProperty(service, key, number);
    CFRelease(number);
}

static int wakeSPUDrivers(void) {
    setStage("creating AppleSPUHIDDriver matching dictionary");
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSPUHIDDriver");
    if (matching == NULL) {
        return NOMAS_ACCEL_ERROR_IOKIT;
    }

    setStage("enumerating AppleSPUHIDDriver services");
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        return NOMAS_ACCEL_ERROR_IOKIT;
    }

    io_service_t service;
    setStage("waking AppleSPUHIDDriver services");
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        setRegistryInt(service, CFSTR("SensorPropertyReportingState"), 1);
        setRegistryInt(service, CFSTR("SensorPropertyPowerState"), 1);
        setRegistryInt(service, CFSTR("ReportInterval"), reportIntervalMicroseconds);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return NOMAS_ACCEL_OK;
}

static void accelReportCallback(void *context,
                                IOReturn result,
                                void *sender,
                                IOHIDReportType type,
                                uint32_t reportID,
                                uint8_t *report,
                                CFIndex reportLength) {
    (void)context;
    (void)result;
    (void)sender;
    (void)type;
    (void)reportID;

    if (report == NULL || reportLength != imuReportLength) {
        return;
    }

    NomasMotionAccelCallback callback;
    void *callbackContext;
    pthread_mutex_lock(&g_lock);
    if (!g_running || g_stopRequested || g_callback == NULL) {
        pthread_mutex_unlock(&g_lock);
        return;
    }

    g_decimationCounter++;
    if (g_decimationCounter < imuDecimation) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_decimationCounter = 0;
    callback = g_callback;
    callbackContext = g_context;
    g_callbacksInFlight++;
    pthread_mutex_unlock(&g_lock);

    int32_t x = readInt32LE(report + imuDataOffset);
    int32_t y = readInt32LE(report + imuDataOffset + 4);
    int32_t z = readInt32LE(report + imuDataOffset + 8);
    setStage("receiving accelerometer samples");
    callback(x, y, z, callbackContext);

    pthread_mutex_lock(&g_lock);
    g_callbacksInFlight--;
    if (g_callbacksInFlight == 0) {
        pthread_cond_broadcast(&g_quiescentCond);
    }
    pthread_mutex_unlock(&g_lock);
}

static void unregisterAccelerometerDevices(void) {
    for (int i = 0; i < g_deviceCount; i++) {
        IOHIDDeviceRef device = g_devices[i].device;
        if (device != NULL) {
            IOHIDDeviceUnscheduleFromRunLoop(
                device,
                CFRunLoopGetCurrent(),
                kCFRunLoopDefaultMode
            );
            IOHIDDeviceClose(device, 0);
            CFRelease(device);
        }
        free(g_devices[i].reportBuffer);
        g_devices[i].device = NULL;
        g_devices[i].reportBuffer = NULL;
    }
    g_deviceCount = 0;
}

static int registerAccelerometerDevices(void) {
    setStage("creating AppleSPUHIDDevice matching dictionary");
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSPUHIDDevice");
    if (matching == NULL) {
        return NOMAS_ACCEL_ERROR_IOKIT;
    }

    setStage("enumerating AppleSPUHIDDevice services");
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        return NOMAS_ACCEL_ERROR_IOKIT;
    }

    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        setStage("inspecting AppleSPUHIDDevice usage");
        bool usagePageOK = false;
        bool usageOK = false;
        int64_t usagePage = registryInt(service, CFSTR("PrimaryUsagePage"), &usagePageOK);
        int64_t usage = registryInt(service, CFSTR("PrimaryUsage"), &usageOK);

        if (usagePageOK && usageOK && usagePage == pageVendor && usage == usageAccelerometer && g_deviceCount < maxDevices) {
            setStage("creating IOHIDDevice for accelerometer");
            IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, service);
            if (device != NULL) {
                setStage("opening IOHIDDevice for accelerometer");
                kr = IOHIDDeviceOpen(device, 0);
                if (kr == kIOReturnSuccess) {
                    setStage("allocating accelerometer report buffer");
                    uint8_t *buffer = calloc(reportBufferSize, sizeof(uint8_t));
                    if (buffer != NULL) {
                        g_devices[g_deviceCount].device = device;
                        g_devices[g_deviceCount].reportBuffer = buffer;
                        g_deviceCount++;

                        setStage("registering accelerometer input report callback");
                        IOHIDDeviceRegisterInputReportCallback(
                            device,
                            buffer,
                            reportBufferSize,
                            accelReportCallback,
                            NULL
                        );
                        setStage("scheduling accelerometer on CFRunLoop");
                        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
                    } else {
                        IOHIDDeviceClose(device, 0);
                        CFRelease(device);
                    }
                } else {
                    CFRelease(device);
                }
            }
        }

        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    if (g_deviceCount > 0) {
        setStage("accelerometer callback registered");
    } else {
        setStage("no accelerometer HID device matched");
    }
    return g_deviceCount > 0 ? NOMAS_ACCEL_OK : NOMAS_ACCEL_ERROR_NO_ACCELEROMETER;
}

static void *sensorThreadMain(void *ignored) {
    (void)ignored;

    setStage("sensor thread started");
    int status = wakeSPUDrivers();
    if (status == NOMAS_ACCEL_OK && !stopRequested()) {
        status = registerAccelerometerDevices();
    }

    pthread_mutex_lock(&g_lock);
    g_startupStatus = status;
    g_startupComplete = true;
    if (status != NOMAS_ACCEL_OK || g_stopRequested) {
        g_running = false;
    }
    pthread_cond_signal(&g_startupCond);
    pthread_mutex_unlock(&g_lock);

    if (status != NOMAS_ACCEL_OK) {
        unregisterAccelerometerDevices();
        pthread_mutex_lock(&g_lock);
        g_running = false;
        pthread_cond_broadcast(&g_quiescentCond);
        pthread_mutex_unlock(&g_lock);
        return NULL;
    }

    setStage("running accelerometer CFRunLoop");
    while (!stopRequested()) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    }

    unregisterAccelerometerDevices();
    pthread_mutex_lock(&g_lock);
    g_running = false;
    // A stop issued by this worker (including from an input callback) cannot
    // join itself. Finish that stop here after the callback and device cleanup
    // have quiesced. An external stop owner performs this finalization after
    // pthread_join returns.
    if (g_stopInProgress && pthread_equal(g_stopOwner, pthread_self())) {
        // No external stop owner can join this worker: the self-stop owner
        // causes other callers to wait for this state transition instead.
        // Detach before returning so this joinable thread's resources are
        // reclaimed when it exits.
        pthread_detach(pthread_self());
        g_threadCreated = false;
        g_stopRequested = false;
        g_stopInProgress = false;
        g_callback = NULL;
        g_context = NULL;
    }
    pthread_cond_broadcast(&g_quiescentCond);
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

int nomas_accel_start(NomasMotionAccelCallback callback, void *context) {
    if (callback == NULL) {
        setStage("blocked before startup: callback is required");
        return NOMAS_ACCEL_ERROR_INVALID_CALLBACK;
    }

    if (geteuid() != 0) {
        setStage("blocked before startup: root/admin privileges required");
        return NOMAS_ACCEL_ERROR_PERMISSION;
    }

    pthread_mutex_lock(&g_lock);
    if (g_threadCreated || g_running || g_stopInProgress) {
        pthread_mutex_unlock(&g_lock);
        return NOMAS_ACCEL_ERROR_ALREADY_RUNNING;
    }

    g_callback = callback;
    g_context = context;
    g_lastStage = "starting accelerometer reader";
    g_startupStatus = NOMAS_ACCEL_ERROR_STARTUP_TIMEOUT;
    g_startupComplete = false;
    g_stopRequested = false;
    g_threadCreated = false;
    g_callbacksInFlight = 0;
    g_deviceCount = 0;
    g_decimationCounter = 0;
    g_running = true;
    int result = pthread_create(&g_thread, NULL, sensorThreadMain, NULL);
    if (result != 0) {
        g_running = false;
        g_callback = NULL;
        g_context = NULL;
        g_stopRequested = false;
        g_stopInProgress = false;
        pthread_cond_broadcast(&g_quiescentCond);
        pthread_mutex_unlock(&g_lock);
        return NOMAS_ACCEL_ERROR_THREAD;
    }
    g_threadCreated = true;
    pthread_mutex_unlock(&g_lock);

    pthread_mutex_lock(&g_lock);
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += startupTimeoutSeconds;
    while (!g_startupComplete && !g_stopRequested) {
        int waitResult = pthread_cond_timedwait(&g_startupCond, &g_lock, &deadline);
        if (waitResult == ETIMEDOUT) {
            break;
        }
        if (waitResult != 0) {
            break;
        }
    }
    int status = (g_startupComplete && !g_stopRequested)
        ? g_startupStatus
        : NOMAS_ACCEL_ERROR_STARTUP_TIMEOUT;
    pthread_mutex_unlock(&g_lock);

    if (status != NOMAS_ACCEL_OK) {
        // A timed-out or failed startup must quiesce the worker before this
        // borrowed context can be released by the caller.
        nomas_accel_stop();
    }
    return status;
}

void nomas_accel_stop(void) {
    pthread_t thread;
    pthread_t caller = pthread_self();

    pthread_mutex_lock(&g_lock);
    if (g_stopInProgress) {
        if (pthread_equal(g_stopOwner, caller)
            || (g_threadCreated && pthread_equal(g_thread, caller))) {
            // The sensor worker must never wait for an external stop owner:
            // that owner is joining this thread. Return so the callback/run
            // loop can unwind and let the external owner finish cleanup.
            pthread_mutex_unlock(&g_lock);
            return;
        }
        while (g_stopInProgress) {
            pthread_cond_wait(&g_quiescentCond, &g_lock);
        }
        pthread_mutex_unlock(&g_lock);
        return;
    }

    if (!g_threadCreated) {
        g_running = false;
        g_stopRequested = false;
        g_callback = NULL;
        g_context = NULL;
        pthread_mutex_unlock(&g_lock);
        return;
    }

    thread = g_thread;
    g_stopInProgress = true;
    g_stopOwner = caller;
    g_stopRequested = true;
    g_running = false;
    pthread_cond_broadcast(&g_startupCond);
    pthread_mutex_unlock(&g_lock);

    // The worker is deliberately joinable. This is the quiescence barrier:
    // once join returns, no HID callback can still hold callbackContext.
    if (pthread_equal(thread, caller)) {
        // sensorThreadMain will finish the state transition after it leaves
        // the current callback/run-loop invocation.
        return;
    }
    pthread_join(thread, NULL);

    pthread_mutex_lock(&g_lock);
    while (g_callbacksInFlight != 0) {
        pthread_cond_wait(&g_quiescentCond, &g_lock);
    }
    g_threadCreated = false;
    g_stopRequested = false;
    g_stopInProgress = false;
    g_running = false;
    g_callback = NULL;
    g_context = NULL;
    pthread_cond_broadcast(&g_quiescentCond);
    pthread_mutex_unlock(&g_lock);
}

const char *nomas_accel_error_message(int code) {
    switch (code) {
        case NOMAS_ACCEL_OK:
            return "accelerometer started";
        case NOMAS_ACCEL_ERROR_PERMISSION:
            return "accelerometer access requires root/admin privileges for the current MVP";
        case NOMAS_ACCEL_ERROR_ALREADY_RUNNING:
            return "accelerometer reader is already running";
        case NOMAS_ACCEL_ERROR_THREAD:
            return "failed to start accelerometer reader thread";
        case NOMAS_ACCEL_ERROR_IOKIT:
            return "IOKit could not enumerate Apple SPU accelerometer services";
        case NOMAS_ACCEL_ERROR_NO_ACCELEROMETER:
            return "no Apple SPU accelerometer HID device was found";
        case NOMAS_ACCEL_ERROR_STARTUP_TIMEOUT:
            return "accelerometer reader startup timed out before IOKit enumeration completed";
        case NOMAS_ACCEL_ERROR_INVALID_CALLBACK:
            return "accelerometer callback is required";
        default:
            return "unknown accelerometer error";
    }
}

const char *nomas_accel_last_stage(void) {
    const char *stage;
    pthread_mutex_lock(&g_lock);
    stage = g_lastStage;
    pthread_mutex_unlock(&g_lock);
    return stage;
}
