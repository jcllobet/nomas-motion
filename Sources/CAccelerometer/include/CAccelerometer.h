#ifndef CACCELEROMETER_H
#define CACCELEROMETER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*NomasMotionAccelCallback)(int32_t x, int32_t y, int32_t z, void *context);

enum {
    NOMAS_ACCEL_OK = 0,
    NOMAS_ACCEL_ERROR_PERMISSION = 1,
    NOMAS_ACCEL_ERROR_ALREADY_RUNNING = 2,
    NOMAS_ACCEL_ERROR_THREAD = 3,
    NOMAS_ACCEL_ERROR_IOKIT = 4,
    NOMAS_ACCEL_ERROR_NO_ACCELEROMETER = 5,
    NOMAS_ACCEL_ERROR_STARTUP_TIMEOUT = 6,
    NOMAS_ACCEL_ERROR_INVALID_CALLBACK = 7
};

int nomas_accel_start(NomasMotionAccelCallback callback, void *context);
// Stops the reader. Calls from an external thread wait until no input
// callback can reference context. Calls from the sensor worker or its input
// callback request shutdown and return so that the worker can unwind; cleanup
// completes before that worker exits. It is safe to call after a failed start
// or when no reader is active.
void nomas_accel_stop(void);
const char *nomas_accel_error_message(int code);
const char *nomas_accel_last_stage(void);

int nomas_unix_socket_connect(int fd, const char *path);
int nomas_unix_socket_bind(int fd, const char *path);

#ifdef __cplusplus
}
#endif

#endif
