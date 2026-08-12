project('ghostty-vt', 'c')

zig = find_program('zig', required: true)
shell = find_program('bash', 'sh', required: true)
build_script = meson.current_source_dir() / '../../scripts/build-ghostty-vt.sh'

ghostty_vt_stamp = custom_target(
    'ghostty-vt-build',
    output: 'ghostty-vt.stamp',
    command: [
        shell,
        build_script,
        zig,
        meson.current_source_dir(),
        '@OUTPUT@',
    ],
    build_by_default: true,
)

ghostty_vt_dep = declare_dependency(
    sources: ghostty_vt_stamp,
    include_directories: include_directories('include'),
    compile_args: ['-DGHOSTTY_STATIC'],
    link_args: [
        meson.current_source_dir() / 'zig-out/lib/ghostty-vt-static.lib',
        '-lntdll',
        '-lkernel32',
    ],
)

