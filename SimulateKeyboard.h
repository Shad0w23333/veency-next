#pragma once
// 历史遗留的空头文件:Tweak.mm 通过 #include "SimulateKeyboard.h" 引用,
// 但实际使用的键盘事件路径走 GSEventCreateKeyEvent / _GSCreateSyntheticKeyEvent (GraphicsServices),
// 不需要 SimulateKeyboard 库的任何符号。保留此空文件以避免修改 Tweak.mm 的 include。
