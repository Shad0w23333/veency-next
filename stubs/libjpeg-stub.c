// libjpeg.62.dylib stub for armv7/iOS6
// 提供 8 个空符号让 dyld 加载通过;只要不用 Tight+JPEG 编码就不会被调用。
void jpeg_CreateCompress(void) {}
void jpeg_destroy_compress(void) {}
void jpeg_finish_compress(void) {}
void jpeg_set_defaults(void) {}
void jpeg_set_quality(void) {}
void jpeg_start_compress(void) {}
void *jpeg_std_error(void *e) { return e; }
void jpeg_write_scanlines(void) {}
