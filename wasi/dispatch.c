#include <stdint.h>

typedef struct dispatch_queue_s *dispatch_queue_t;

extern dispatch_queue_t dispatch_get_main_queue(void);
extern uint64_t dispatch_time(uint64_t when, int64_t delta_ns);
extern void dispatch_after(uint64_t when, dispatch_queue_t queue, void (^work)(void));

void ghostty_wasi_dispatch_after(int64_t delay_ns, void *context, void (*work)(void *)) {
    dispatch_after(dispatch_time(0, delay_ns), dispatch_get_main_queue(), ^{
        work(context);
    });
}
