project('ghostty-vt', 'c')

zig = find_program('zig', required: true)
shell = find_program('bash', 'sh', required: true)
build_script = files('build-vt.sh')
input_config = configuration_data()
input_config.set_quoted('ANVIL_GHOSTTY_INPUTS', import('fs').read('../.anvil-wrap-state/ghostty').strip())
input_stamp = configure_file(output: 'ghostty-inputs.h', configuration: input_config)

ghostty_vt_library = custom_target(
    'ghostty-vt-build',
    output: 'ghostty-vt-static.lib',
    command: [
        shell,
        build_script,
        zig,
        meson.current_source_dir(),
        '@OUTPUT@',
    ],
    depend_files: [input_stamp, build_script],
    build_by_default: true,
)

ghostty_vt_dep = declare_dependency(
    link_with: ghostty_vt_library,
    include_directories: include_directories('include'),
    compile_args: ['-DGHOSTTY_STATIC'],
    link_args: [
        '-lntdll',
        '-lkernel32',
    ],
)

