# WARNING! Use at your own risk!

# bluetoothimport
Sync bluetooth pairing keys from windows to linux

# Usage
1. Boot to linux and pair your bluetooth devices
2. Reboot to windows and pair them again
3. Reboot to linux and run this script. Don't `sudo`, the script will `sudo` when needed.

# Dependencies
- hivexregedit. Usually found in your system package manager

# Trivia
- The script will enumerate your ntfs volumes to try to find windows directory (assumed to reside in `Windows` directory in the root of a volume). The needed keys are extracted from windows registry and imported to linux bluetooth settings (assumed to reside in `/var/lib/bluetooth/ADAPTER_MAC`). The script will ask if import is needed for every applicable device.

Contributions are welcome! ;)
