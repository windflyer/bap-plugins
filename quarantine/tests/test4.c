//! c:malloc@00000192

#include <stdlib.h>

int init(void *p) {
    p = NULL;
}

int check(void *p) {
    if (!p) exit(1);
}

int main() {
    char *p;
    init(p);
    p = (char *) malloc(42);
    check(p);
    p[0] = '\n';
}