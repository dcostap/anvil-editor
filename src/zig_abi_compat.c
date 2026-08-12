/* Zig's x86_64 Windows output uses the MSVC stack-probe symbol.
 * MinGW provides the same probe with its historical extra underscore. */
#if defined(_WIN32) && defined(__x86_64__) && defined(__GNUC__)
extern void ___chkstk_ms(void);

__attribute__((naked)) void __chkstk(void) {
  __asm__ volatile("jmp ___chkstk_ms");
}
#endif
