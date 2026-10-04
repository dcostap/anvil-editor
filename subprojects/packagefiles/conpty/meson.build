project('conpty', version: '1.24.261001001', license: 'MIT')

arch = {'x86_64': 'x64', 'x86': 'x86', 'aarch64': 'arm64'}.get(host_machine.cpu_family())
conpty_runtime_files = [
    files('runtimes/win-' + arch + '/native/conpty.dll')[0],
    files('build/native/runtimes/' + arch + '/OpenConsole.exe')[0],
]
install_data(conpty_runtime_files, install_dir: get_option('data_dir') / 'conpty')
