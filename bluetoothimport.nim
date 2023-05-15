#!/usr/bin/env -S nim r
import osproc, json, os, streams, tables, strutils, algorithm
import tempdir

proc getBlockDevices(): JsonNode =
  let (o, res) = execCmdEx("lsblk --fs --json")
  doAssert(res == 0)
  parseJson(o)["blockdevices"]

proc getNtfsVolumes(): seq[string] =
  for d in getBlockDevices():
    let ch = d{"children"}
    if not ch.isNil:
      for v in ch:
        if v{"fstype"}.getStr() == "ntfs":
          result.add(v["name"].getStr())

template withMountedDevice(device: string, code: untyped) =
  let mountPoint {.inject.} = createTempDirectory("bluetoothimport_win_mount", "/tmp/")
  let (o, res) = execCmdEx("sudo mount -o ro /dev/" & device & " " & mountPoint)
  if res == 0:
    try:
      code
    finally:
      discard execCmdEx("sudo umount " & mountPoint)
  else:
    echo o
    echo "Could not mount ", device

proc getBluetoothRegistryData(path: string): string =
  let regFile = path & "/Windows/System32/config/SYSTEM"
  if fileExists(regFile):
    let (o, res) = execCmdEx("hivexregedit --export " & regFile & " \\\\ControlSet001\\\\Services\\\\BTHPORT\\\\Parameters")
    if res == 0:
      result = o
    else:
      echo "Error exporting registry ", res
      echo o

proc getConfigSections(config: string): seq[string] =
  for l in splitLines(config):
    if l.startsWith("["):
      result.add(l[1 .. ^2])

proc getIniSectionValue(config, section, key: string): string =
  let sectionBegin = "[" & section & "]"
  let keyBegin = key & "="
  type State = enum
    notFound
    inSection

  var state = notFound

  for l in splitLines(config):
    case state
    of notFound:
      if l == sectionBegin:
        state = inSection
    of inSection:
      if l.startsWith(keyBegin):
        return l[keyBegin.len .. ^1]
      elif l.startsWith("["):
        break

proc getConfigSectionValue(config, section, key: string): string =
  getIniSectionValue(config, section, "\"" & key & "\"")

proc getConfigSubSections(config, section: string): seq[string] =
  let prefix = "[" & section & "\\"
  for l in splitLines(config):
    if l.startsWith(prefix) and l.endsWith("]") and l.find("\\", prefix.len) == -1:
      result.add(l[1 .. ^2])

proc configStringToHex(s: string): string =
  assert(s.startsWith("hex("))
  s.split(":")[1].split(",").join().toUpperAscii()

proc configStringToHexReversed(s: string): string =
  assert(s.startsWith("hex("))
  s.split(":")[1].split(",").reversed().join().toUpperAscii()

proc configStringToInt(s: string): int =
  assert(s.startsWith("dword:"))
  s.split(":")[1].parseHexInt()

proc lastPathComponent(s: string): string =
  let i = s.rfind("\\")
  assert(i != -1)
  s[i + 1 .. ^1]

proc erandToDecimal(s: string): uint64 =
  let erandStr = s.align(16, '0').parseHexStr()
  cast[ptr uint64](unsafeAddr erandStr[0])[]

proc sudoLs(path: string): seq[string] =
  let (o, res) = execCmdEx("sudo ls \"" & path & "\"")
  if res != 0:
    raise newException(OSError, "Could not ls: " & o)
  o.splitLines()[0 .. ^2]

proc sudoMv(src, dst: string) =
  let (o, res) = execCmdEx("sudo mv \"" & src & "\" \"" & dst & "\"")
  if res != 0:
    raise newException(OSError, "Could not mv: " & o)

proc sudoWriteFile(path, content: string) =
  writeFile("/tmp/bluetoothimport.tmp", content)
  let (o, res) = execCmdEx("sudo cp /tmp/bluetoothimport.tmp \"" & path & "\"")
  if res != 0:
    raise newException(OSError, "Could not write file: " & o)

proc patchIniSectionValue(config: var string, section, key, value: string): bool =
  var res = ""
  let sectionBegin = "[" & section & "]"
  let keyBegin = key & "="
  type State = enum
    notFound
    inSection
    outOfSection

  var state = notFound
  for l in splitLines(config):
    var ll = l
    case state
    of notFound:
      if l == sectionBegin:
        state = inSection
    of inSection:
      if l.startsWith(keyBegin):
        ll = keyBegin & value
        echo "Patching: ", section, ".", ll
        result = true
      elif l.startsWith("["):
        state = outOfSection
    else:
      discard
    res &= ll
    res &= "\n"

  config = res

proc getLinuxDevices(): seq[string] =
  let btRoot = "/var/lib/bluetooth/" & sudoLs("/var/lib/bluetooth")[0]
  for s in sudoLs(btRoot):
    if s.find(":") != -1:
      let f = execCmdEx("sudo cat " & btRoot & "/" & s & "/info")[0]
      let name = getIniSectionValue(f, "General", "Name")
      result.add(name)

proc prompt(s: string): bool =
  while true:
    write(stdout, s)
    var input = readLine(stdin).strip().toLowerAscii()
    case input
    of "y": return true
    of "n": return false
    else: discard

proc hexMacAddrToCanonical(s: string): string =
  for i, c in s:
    if i mod 2 == 0 and i != 0:
      result &= ":"
    result &= c
  toUpperAscii(result)

proc getConfigSectionValueAsString(regdata, section, key: string): string =
  result = getConfigSectionValue(regdata, section, key)
  if result.len > 0:
    result = result.configStringToHex().parseHexStr()
    if result.endsWith('\0'): result.setLen(result.len - 1)

proc main() =
  if findExe("hivexregedit").len == 0:
    echo "hivexregedit not found. Install it to use this tool."
    quit(1)

  var importHappened = false
  var btregdata = ""
  for v in getNtfsVolumes():
    withMountedDevice(v):
      btregdata = getBluetoothRegistryData(mountPoint)
      if btregdata.len != 0:
        break
  if btregdata.len == 0:
    echo "Could not find windows registry"
  else:
    var linuxDevices = getLinuxDevices()
    let keysRootKey = getConfigSubsections(btregdata, "\\ControlSet001\\Services\\BTHPORT\\Parameters\\Keys")[0]
    # echo btregdata
    for s in getConfigSubsections(btregdata, "\\ControlSet001\\Services\\BTHPORT\\Parameters\\Devices"):
      var n = getConfigSectionValueAsString(btregdata, s, "LEName")
      var simpleMode = false
      if n.len == 0:
        simpleMode = true
        n = getConfigSectionValueAsString(btregdata, s, "Name")
      let k = s.lastPathComponent
      let keyExists = getConfigSectionValue(btregdata, keysRootKey, k) != ""
      if n.len != 0 and n in linuxDevices and (keyExists or not simpleMode) and prompt("Import " & n & "? (Y/N): "):
        let btRoot = "/var/lib/bluetooth/" & sudoLs("/var/lib/bluetooth")[0]
        for ls in sudoLs(btRoot):
          if ls.find(":") != -1:
            var f = execCmdEx("sudo cat " & btRoot & "/" & ls & "/info")[0]
            let name = getIniSectionValue(f, "General", "Name")
            if name == n:
              let nk = hexMacAddrToCanonical(k)
              if simpleMode:
                discard patchIniSectionValue(f, "LinkKey", "Key", getConfigSectionValue(btregdata, keysRootKey, k).configStringToHex())
              else:
                let ks = keysRootKey & "\\" & k
                discard patchIniSectionValue(f, "LongTermKey", "Key", getConfigSectionValue(btregdata, ks, "LTK").configStringToHex())
                discard patchIniSectionValue(f, "LongTermKey", "EncSize", $getConfigSectionValue(btregdata, ks, "KeyLength").configStringToInt())
                discard patchIniSectionValue(f, "LongTermKey", "Rand", $getConfigSectionValue(btregdata, ks, "ERand").configStringToHex().erandToDecimal())
                discard patchIniSectionValue(f, "LongTermKey", "EDiv", $getConfigSectionValue(btregdata, ks, "EDIV").configStringToInt())
                discard patchIniSectionValue(f, "LocalSignatureKey", "Key", getConfigSectionValue(btregdata, ks, "CSRK"))
                discard patchIniSectionValue(f, "IdentityResolvingKey", "Key", getConfigSectionValue(btregdata, ks, "IRK").configStringToHexReversed())
              echo "mv ", btRoot & "/" & ls, " -> ", btRoot & "/" & nk
              if ls != nk:
                sudoMv(btRoot & "/" & ls, btRoot & "/" & nk)
              sudoWriteFile(btRoot & "/" & nk & "/info", f)
              importHappened = true
              # echo f
              break
  if importHappened:
    echo "run: systemctl restart bluetooth"

main()
