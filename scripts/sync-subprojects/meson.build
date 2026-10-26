# Run before Meson opens any cached Git subproject.
subproject_python = import('python').find_installation()
subproject_sync = run_command(
    subproject_python,
    files('../sync-git-subprojects.py'),
    meson.project_source_root(),
    subproject_python.full_path(), '-m', 'mesonbuild.mesonmain',
    check: true,
)
if subproject_sync.stderr().strip() != ''
    message(subproject_sync.stderr().strip())
endif
# Include patch contents, not only wrap files, in Meson's regeneration inputs.
subproject_fs = import('fs')
foreach input : subproject_sync.stdout().strip().split('\n')
    if input != ''
        subproject_fs.read(input)
    endif
endforeach
