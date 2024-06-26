from os import system
from shutil import which
import os.path
from glob import glob
import platform
from sys import argv

is_root = argv[1] == '--root' if len(argv) > 1 else False

# Check for Cabal and XMake 
if not which('cabal') or not which('xmake'):
  print('Please install cabal and xmake')
  exit(1)

# Check for submodules
if not os.path.isdir('runtime'):
  print('Please initialize submodules')
  exit(1)

# Build the compiler project
system('cabal build')

ext = '.exe' if platform.system() == 'Windows' else ''

executable_name = f"plume{ext}"

found_executables = glob(f"dist-newstyle/**/{executable_name}", recursive=True)
executable_files = [file for file in found_executables if os.path.isfile(file)]

if len(executable_files) == 0:
  print('No executable found')
  exit(1)

executable = executable_files[0]
executable_out = f"plumec{ext}"

if not os.path.isdir('bin'): os.mkdir('bin')

system(f"cp {executable} bin/{executable_out}")

# Build the runtime project

runtime_executable = f"plume-vm{ext}"
runtime_executable_out = f"plume{ext}"

xmake_root = '--root' if is_root else ''
system(f'xmake b {xmake_root} -P runtime')
system(f"cp runtime/bin/{runtime_executable} bin/{runtime_executable_out}")

system(f'xmake config {xmake_root} -P standard --ccache=n -y')
system(f'xmake b {xmake_root} -P standard')

print('Build ran successfully')