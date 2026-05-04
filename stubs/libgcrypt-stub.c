// libgcrypt.11.dylib stub for armv7/iOS6
// libvncserver 不调用任何 gcrypt 符号,只是加载命令里有这个依赖。
// 必须有一个真实导出符号才能让 ld 生成 dylib。
void __veency_gcrypt_stub_anchor(void) {}
