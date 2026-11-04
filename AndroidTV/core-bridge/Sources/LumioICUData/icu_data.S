// Lumio's trimmed ICU data (AndroidTV/Tools/build_icu_data.sh), in place of the 32 MB set inside
// Swift's _FoundationICU. It defines the same symbol, so the linker takes this one and leaves
// Swift's copy out. LUMIO_ICU_DATA is the data file's path (Package.swift).
    .section .rodata.icudt76_dat,"a"
    .globl icudt76_dat
    .type icudt76_dat, %object
    .balign 16
icudt76_dat:
    .incbin LUMIO_ICU_DATA
    .size icudt76_dat, . - icudt76_dat
