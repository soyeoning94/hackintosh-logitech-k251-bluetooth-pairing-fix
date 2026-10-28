// 手工链接 kext 时 ld 不会自动生成 _kmod_info，缺它 OpenCore/KXLD 会直接丢弃 kext。
#include <mach/kmod.h>

extern "C" {
kern_return_t IntelBTPatcher_kern_start(kmod_info_t *ki, void *data);
kern_return_t IntelBTPatcher_kern_stop(kmod_info_t *ki, void *data);

kmod_info_t KMOD_INFO_NAME __attribute__((used)) = {
    nullptr,                 // next
    KMOD_INFO_VERSION,       // info_version
    static_cast<uint32_t>(-1), // id
    { "com.zxystd.IntelBTPatcher" }, // name
    { "2.5.1" },             // version
    -1,                      // reference_count
    nullptr,                 // reference_list
    0,                       // address
    0,                       // size
    0,                       // hdr_size
    &IntelBTPatcher_kern_start,
    &IntelBTPatcher_kern_stop
};
}
