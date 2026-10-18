// Cross-check: decompress Swift-produced LZO fixtures with the reference liblzo2.
//   LZO_FIXTURE_DIR=/tmp/x swift test --filter testDumpFixturesForLiblzo
//   cc scripts/verify-lzo.c -I$(brew --prefix lzo)/include -L$(brew --prefix lzo)/lib -llzo2 -o verify-lzo
//   ./verify-lzo /tmp/x
#include <lzo/lzo1x.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *slurp(const char *path, long *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); *len = ftell(f); rewind(f);
    unsigned char *buf = malloc(*len + 1);
    fread(buf, 1, *len, f); fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 2 || lzo_init() != LZO_E_OK) return 2;
    int failures = 0;
    for (int i = 0; ; i++) {
        char raw_path[1024], lzo_path[1024];
        snprintf(raw_path, sizeof raw_path, "%s/case%d.raw", argv[1], i);
        snprintf(lzo_path, sizeof lzo_path, "%s/case%d.lzo", argv[1], i);
        long raw_len, lzo_len;
        unsigned char *raw = slurp(raw_path, &raw_len), *comp = slurp(lzo_path, &lzo_len);
        if (!raw || !comp) { printf("checked %d cases, %d failures\n", i, failures); return failures != 0; }
        unsigned char *out = malloc(raw_len + 1);
        lzo_uint out_len = raw_len;
        int rc = lzo1x_decompress_safe(comp, lzo_len, out, &out_len, NULL);
        int ok = rc == LZO_E_OK && out_len == (lzo_uint)raw_len && memcmp(out, raw, raw_len) == 0;
        printf("case%d: %ld -> %ld bytes, rc=%d %s\n", i, raw_len, lzo_len, rc, ok ? "OK" : "FAIL");
        failures += !ok;
    }
}
