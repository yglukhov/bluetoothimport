# Package

version       = "0.1.0"
author        = "Yuriy Glukhov"
description   = "Sync bluetooth pairing keys across linux and windows"
license       = "MIT"
bin           = @["bluetoothimport"]


# Dependencies
requires "nim >= 1.4.2"
requires "tempdir"
