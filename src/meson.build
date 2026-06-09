anvil_sources = [
    'api/api.c',
    'api/dirmonitor.c',
    'api/renderer.c',
    'api/renwindow.c',
    'api/regex.c',
    'api/system.c',
    'api/process.c',
    'api/channel.c',
    'api/thread.c',
    'api/shmem.c',
    'api/canvas.c',
    'api/utf8.c',
    'api/tokenizer.c',
    'api/fuzzy.c',
    'fuzzy.c',
    'text/piece_tree.c',
    'text/buffer.c',
    'text/buffer_manager.c',
    'text/editor.c',
    'tokenizer/arena.c',
    'tokenizer/regex.c',
    'tokenizer/lutf8.c',
    'api/encoding.c',
    'api/diff.c',
    'api/utils/lxlauxlib.c',
    'arena_allocator.c',
    'custom_events.c',
    'system_events.c',
    'win32_single_instance.c',
    'resize_diagnostics.c',
    'renderer.c',
    'renwindow.c',
    'rencache.c',
    'main.c',
]

if lua_jit_found
    anvil_sources += 'ffiexports.c'
    # Export all local symbols for LuaJIT FFI Access
    if host_machine.system() != 'windows' and host_machine.system() != 'darwin'
        # reminder: on mingw the valid flag is -Wl,--export-all-symbols
        anvil_link_args += '-Wl,--export-dynamic'
    elif host_machine.system() == 'darwin'
        # macOS export dynamic symbols option slightly different
        anvil_link_args += '-Wl,-export_dynamic'
    endif
endif

dirmonitor_backends = get_option('dirmonitor_backends')

if dirmonitor_backends.length() == 0
    if cc.has_function('inotify_init', prefix : '#include<sys/inotify.h>')
        dirmonitor_backends += 'inotify'
    endif

    if host_machine.system() == 'darwin' and cc.check_header('CoreServices/CoreServices.h')
        dirmonitor_backends += 'fsevents'
    endif

    if cc.has_function('kqueue', prefix : '#include<sys/event.h>')
        dirmonitor_backends += 'kqueue'
    endif

    if cc.has_function('create_inode_watcher', prefix : '#include<fcntl.h>')
        dirmonitor_backends += 'inodewatcher'
    endif

    if dependency('libkqueue', required : false, method: 'pkg-config').found()
        dirmonitor_backends += 'kqueue'
    endif

    if host_machine.system() == 'windows'
        dirmonitor_backends += 'win32'
    endif

    dirmonitor_backends += 'dummy'
endif

foreach backend : dirmonitor_backends
    if backend == 'inotify'
        anvil_sources += 'api' / 'dirmonitor' / 'inotify.c'
        anvil_cargs += '-DDIRMONITOR_INOTIFY'
    elif backend == 'fsevents'
        anvil_sources += 'api' / 'dirmonitor' / 'fsevents.c'
        anvil_cargs += '-DDIRMONITOR_FSEVENTS'
    elif backend == 'kqueue'
        anvil_sources += 'api' / 'dirmonitor' / 'kqueue.c'
        libkqueue_dep = dependency('libkqueue', required : false, method: 'pkg-config')
        if libkqueue_dep.found()
            anvil_deps += libkqueue_dep
        endif
        anvil_cargs += '-DDIRMONITOR_KQUEUE'
    elif backend == 'inodewatcher'
        add_languages('cpp')
        anvil_sources += 'api' / 'dirmonitor' / 'inodewatcher.cpp'
        anvil_cargs += '-DDIRMONITOR_INODEWATCHER'
    elif backend == 'win32'
        anvil_sources += 'api' / 'dirmonitor' / 'win32.c'
        anvil_cargs += '-DDIRMONITOR_WIN32'
    elif backend == 'dummy'
        anvil_sources += 'api' / 'dirmonitor' / 'dummy.c'
        anvil_cargs += '-DDIRMONITOR_DUMMY'
    else
        error('Unknown dirmonitor backend @0@'.format(backend))
    endif
endforeach

summary('dirmonitor backends', dirmonitor_backends)

# luajit compatibility files
if lua_compat_needed
    anvil_sources += [
        'compat/liolib.c',
        'compat/lstrlib.c',
        'compat/ltablib.c',
        'compat/lutf8lib.c'
    ]

    if not lua_jit_found
        anvil_sources += 'compat/ljbitlib.c'
    endif
endif

message('lua-compat-5.3 needed: @0@'.format(lua_compat_needed))

anvil_rc = []
if host_machine.system() == 'windows'
    windows = import('windows')
    anvil_sources += ['win32_frame.c', 'd3d11_backend.c']
    anvil_deps += cc.find_library('dwmapi', required: true)
    anvil_deps += cc.find_library('d3d11', required: true)
    anvil_deps += cc.find_library('dxgi', required: true)
    anvil_deps += cc.find_library('dxguid', required: true)
    anvil_deps += cc.find_library('d3dcompiler', required: true)
    anvil_rc += windows.compile_resources('../resources/icons/icon.rc')
    anvil_rc += windows.compile_resources('../resources/windows/manifest.rc')

    # solve missing symbols when building from sdl3 cmake subproject
    if sdl_dep.type_name() == 'internal'
        anvil_deps += cc.find_library('winmm', required : true)
        anvil_deps += cc.find_library('imm32', required: true)
        anvil_deps += cc.find_library('setupapi', required: true)
        anvil_deps += cc.find_library('version', required: true)
        anvil_deps += cc.find_library('iconv', required: false)
    endif

    if cc.get_id() == 'gcc' and get_option('b_pgo') == 'generate'
        # MinGW GCC does not always inject libgcov for static PGO links.
        anvil_deps += cc.find_library('gcov', required: true)
    endif
elif host_machine.system() == 'darwin'
    anvil_sources += 'bundle_open.m'

    # solve missing symbols when building from sdl3 cmake subproject
    if sdl_dep.type_name() == 'internal'
        anvil_link_args += [
            '-framework', 'Carbon',
            '-framework', 'CoreFoundation',
            '-framework', 'Metal',
            '-framework', 'AppKit',
            '-framework', 'CoreVideo',
            '-framework', 'IOKit',
            '-framework', 'UniformTypeIdentifiers'
        ]
    endif
endif

anvil_includes += include_directories('.')

anvil_test_env = environment()
anvil_test_env.set('SDL_VIDEO_DRIVER', 'dummy')
if host_machine.system() == 'windows'
    # Keep Meson failure output printable on machines with non-ASCII or hidden
    # characters in PATH while preserving tools used by runtime tests.
    anvil_test_env.set('PATH', [
        'C:/msys64/mingw64/bin',
        'C:/msys64/usr/bin',
        'C:/Program Files/Git/usr/bin',
        'C:/Program Files/Git/mingw64/bin',
        'C:/Python312',
        'C:/Python312/Scripts',
        'C:/Windows/system32',
        'C:/Windows',
        'C:/Windows/System32/Wbem',
        'C:/Windows/System32/WindowsPowerShell/v1.0',
        'C:/Windows/System32/OpenSSH',
    ])
endif

fuzzy_test = executable('fuzzy_test',
    ['../tests/native/fuzzy_test.c', 'fuzzy.c'],
    include_directories: anvil_includes,
    c_args: anvil_cargs,
)
test('fuzzy', fuzzy_test, env: anvil_test_env)

piece_tree_test = executable('piece_tree_test',
    ['../tests/native/piece_tree_test.c', 'text/piece_tree.c'],
    include_directories: anvil_includes,
    c_args: anvil_cargs,
)
test('piece_tree', piece_tree_test, env: anvil_test_env)

buffer_manager_test = executable('buffer_manager_test',
    [
        '../tests/native/buffer_manager_test.c',
        'text/piece_tree.c',
        'text/buffer.c',
        'text/buffer_manager.c',
    ],
    include_directories: anvil_includes,
    c_args: anvil_cargs,
)
test('buffer_manager', buffer_manager_test, env: anvil_test_env)

editor_test = executable('editor_test',
    [
        '../tests/native/editor_test.c',
        'text/piece_tree.c',
        'text/buffer.c',
        'text/buffer_manager.c',
        'text/editor.c',
    ],
    include_directories: anvil_includes,
    c_args: anvil_cargs,
)
test('editor', editor_test, env: anvil_test_env)

# load and configure linenoise
if get_option('repl_history')
    if lua_jit_found
        linenoise_jit = 'jit=true'
    else
        linenoise_jit = 'jit=false'
    endif
    anvil_deps += subproject('linenoise',
        default_options: default_fallback_options + [
            'default_library=static', linenoise_jit
        ]
    ).get_variable('linenoise_dep')
    anvil_cargs += '-DANVIL_REPL_HISTORY'
endif

# enable networking support
if get_option('net')
    anvil_deps += dependency('SDL3_net', 'sdl3-net', fallback: ['sdl3_net', 'sdl3_net_dep'],
        default_options: default_fallback_options + ['default_library=static']
    )

    use_system_mbedtls = get_option('wrap_mode') != 'forcefallback'

    mbedtls_dep = disabler()
    mbedx509_dep = disabler()
    tfpsacrypto_dep = disabler()
    system_mbedtls_ok = false

    if use_system_mbedtls
        mbedtls_dep = dependency('mbedtls', version: '>=4.0.0', required: false)
        mbedx509_dep = dependency('mbedx509', version: '>=4.0.0', required: false)
        tfpsacrypto_dep = dependency('tfpsacrypto', required: false)
        system_mbedtls_ok = mbedtls_dep.found() and mbedx509_dep.found() and tfpsacrypto_dep.found()
    endif

    if not use_system_mbedtls or not system_mbedtls_ok
        mbedtls = subproject('mbedtls',
            default_options: default_fallback_options + ['default_library=static']
        )
        mbedtls_dep = mbedtls.get_variable('mbedtls_dep')
        mbedx509_dep = mbedtls.get_variable('mbedx509_dep')
        tfpsacrypto_dep = mbedtls.get_variable('tfpsacrypto_dep')
    endif

    anvil_deps += [mbedtls_dep, mbedx509_dep, tfpsacrypto_dep]

    anvil_sources += 'api/net.c'
    anvil_cargs += '-DANVIL_NET'
endif

anvil_exe = executable('anvil',
    anvil_sources + anvil_rc,
    include_directories: anvil_includes,
    dependencies: anvil_deps,
    c_args: anvil_cargs,
    objc_args: anvil_cargs,
    link_args: anvil_link_args,
    link_whole: anvil_link_whole,
    install_dir: anvil_bindir,
    install: true,
    win_subsystem: 'windows',
)

if host_machine.system() == 'windows'
    executable('anvil',
        anvil_sources + anvil_rc,
        include_directories: anvil_includes,
        dependencies: anvil_deps,
        c_args: anvil_cargs,
        objc_args: anvil_cargs,
        link_args: anvil_link_args,
        link_whole: anvil_link_whole,
        name_suffix: 'com',
        install_dir: anvil_bindir,
        install: true,
        win_subsystem: 'console',
    )
endif

lua_test_runner = files('../tests/run-lua-tests.sh')
lua_test_shell = find_program('bash', 'sh')

test('lua-runtime', lua_test_shell,
    args: [
        lua_test_runner,
        anvil_build_root,
        anvil_source_root,
        anvil_exe.full_path(),
        'tests/lua/runtime',
        'lua-runtime',
    ],
    env: anvil_test_env,
    depends: anvil_exe,
    timeout: 120,
    is_parallel: false,
)

test('lua-ui', lua_test_shell,
    args: [
        lua_test_runner,
        anvil_build_root,
        anvil_source_root,
        anvil_exe.full_path(),
        'tests/lua/ui',
        'lua-ui',
    ],
    env: anvil_test_env,
    depends: anvil_exe,
    timeout: 180,
    is_parallel: false,
)
