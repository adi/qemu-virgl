/* Minimal C11 threads.h shim for macOS using pthreads */
#pragma once
#include <pthread.h>
#include <time.h>

typedef pthread_t thrd_t;
typedef int (*thrd_start_t)(void *);

enum { thrd_success = 0, thrd_error = 1, thrd_timedout = 2, thrd_busy = 3, thrd_nomem = 4 };

static inline int thrd_create(thrd_t *thr, thrd_start_t func, void *arg) {
    return pthread_create(thr, NULL, (void *(*)(void *))func, arg) ? thrd_error : thrd_success;
}
static inline int thrd_join(thrd_t thr, int *res) {
    void *retval;
    if (pthread_join(thr, &retval)) return thrd_error;
    if (res) *res = (int)(intptr_t)retval;
    return thrd_success;
}
static inline int thrd_equal(thrd_t a, thrd_t b) { return pthread_equal(a, b); }
static inline thrd_t thrd_current(void) { return pthread_self(); }
static inline int thrd_detach(thrd_t thr) { return pthread_detach(thr) ? thrd_error : thrd_success; }
static inline void thrd_exit(int res) { pthread_exit((void *)(intptr_t)res); }
static inline int thrd_sleep(const struct timespec *dur, struct timespec *rem) {
    return nanosleep(dur, rem);
}
