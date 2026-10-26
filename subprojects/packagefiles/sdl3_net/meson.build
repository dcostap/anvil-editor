project('sdl3_net', 'c', version: '3.1.0')

cc = meson.get_compiler('c')

sdl_dep = dependency('sdl3', version: '>=3.2.4')
net_dependencies = [sdl_dep]
net_args = []
host = host_machine.system()

if host == 'windows'
  # SDL_net defines its own static read() and write() for sockets. New MinGW headers
  # reach io.h through wchar.h, and its POSIX names conflict with them.
  net_args += '-DNO_OLDNAMES'
  net_dependencies += cc.find_library('iphlpapi')
  net_dependencies += cc.find_library('ws2_32')
elif host == 'haiku'
  net_dependencies += cc.find_library('network')
endif

net_src = files(
  'src/SDL_net.c'
)

net_lib = library('sdl3_image',
  net_src,
  c_args: net_args,
  include_directories: 'include',
  dependencies: net_dependencies
)

sdl3_net_dep = declare_dependency(
  include_directories: 'include',
  link_with: net_lib
)
