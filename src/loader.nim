import endians


# TODO convert everything back to fread
proc readFile(fname: string): seq[uint8] =
  var f: File
  if not open(f, fname, fmRead):
    raise newException(IOError, "Cannot open file: '" & fname & "'")

  let size = f.getFileSize()
  newSeq(result, size)

  let read = f.readBuffer(result[0].addr, size)
  if read != size:
    raise newException(IOError, "Error reading file '" & fname & "'")

  f.close()


proc mkTag(tag: string): int =
  assert tag.len == 4
  result =  cast[int](tag[0]) +
            cast[int](tag[1]) shl  8 +
            cast[int](tag[2]) shl 16 +
            cast[int](tag[3]) shl 24


proc determineModuleType(tag: int): (ModuleType, int) =
  # based on https://wiki.multimedia.cx/index.php?title=Protracker_Module

  proc digitToInt(c: char): int = c.int - '0'.int

  proc firstDigitToInt(tag: int): int =
    digitToInt(cast[char]((tag and 0xff000000) shr 24))

  proc lastDigitToInt(tag: int): int =
    digitToInt(cast[char](tag and 0xff))

  proc firstTwoDigitsToInt(tag: int): int =
    let
      digit1 = digitToInt(cast[char]((tag and 0xff000000) shr 24))
      digit2 = digitToInt(cast[char]((tag and 0x00ff0000) shr 16))
    result = digit1 * 10 + digit2


  if tag == mkTag("M.K.") or tag == mkTag("M!K!"):
    result = (mtProtracker, 4)

  elif tag == mkTag("2CHN") or tag == mkTag("4CHN") or
       tag == mkTag("6CHN") or tag == mkTag("8CHN"):
    result = (mtFastTracker, firstDigitToInt(tag))

  elif tag == mkTag("CD81") or tag == mkTag("OKTA"):
    result = (mtOktalyzer, 8)

  elif tag == mkTag("OCTA"):
    result = (mtOctaMED, 8)

  elif (tag and 0xffff) == (mkTag("xxCH") and 0xffff):
    let chans = firstTwoDigitsToInt(tag)
    assert chans >= 10 and chans <= 32
    assert chans mod 2 == 0
    result = (mtFastTracker, chans)

  elif (tag and 0xffff) == (mkTag("xxCN") and 0xffff):
    result = (mtTakeTracker, firstTwoDigitsToInt(tag))

  elif tag == mkTag("TDZ1") or tag == mkTag("TDZ2") or tag == mkTag("TDZ3"):
    result = (mtTakeTracker, lastDigitToInt(tag))

  elif tag == mkTag("5CHN") or tag == mkTag("7CHN") or tag == mkTag("9CHN"):
    result = (mtTakeTracker, firstDigitToInt(tag))

  elif tag == mkTag("FLT4") or tag == mkTag("FLT8"):
    result = (mtStarTrekker, lastDigitToInt(tag))


proc loadSample(buf: var seq[uint8], pos: var int): Sample =
  var samp = newSample()

  var name = cast[cstring](alloc0(MAX_SAMPLE_NAME_LEN + 1))
  copyMem(name, buf[pos].addr, MAX_SAMPLE_NAME_LEN)
  samp.name = $name
  pos += MAX_SAMPLE_NAME_LEN

  bigEndian16(samp.length.addr, buf[pos].addr)
  samp.length *= 2
  pos += 2

  let finetune: uint8 = buf[pos] and 0xf
  # sign extend 4-bit signed nibble to 8-bit
  if (finetune and 0x08) > 0'u8:
    samp.finetune = cast[int8](finetune or 0xf0'u8)
  pos += 1

  samp.volume = int(buf[pos])
  pos += 1

  bigEndian16(samp.repeatOffset.addr, buf[pos].addr)
  samp.repeatOffset *= 2
  pos += 2

  bigEndian16(samp.repeatLength.addr, buf[pos].addr)
  samp.repeatLength *= 2
  pos += 2

  result = samp


proc periodToNote(period: int): int =
  if period == 0:
    return NOTE_NONE

  for i, p in periodTable.pairs:
    if p == period:
      return i
  raise newException(ValueError, "Invalid period value: " & $period)


proc loadPattern(buf: var seq[uint8], pos: var int,
                 numChannels: int): Pattern =

  var patt = newPattern(numChannels)

  for rowNum in 0..<ROWS_PER_PATTERN:
    for trackNum in 0..<numChannels:
      var cell = newCell()
      cell.note = periodToNote(((buf[pos] and 0x0f).int shl 8) or
                                 buf[pos+1].int)

      cell.sampleNum =  (buf[pos]   and 0xf0).int or
                       ((buf[pos+2] and 0xf0).int shr 4)

      cell.effect = ((buf[pos+2] and 0x0f).int shl 8) or
                      buf[pos+3].int

      patt.tracks[trackNum].rows[rowNum] = cell
      pos += BYTES_PER_CELL

  result = patt


# TODO add lots of validation
proc loadModule*(buf: var seq[uint8]): Module =
  var module = newModule()
  var pos = 0

  # read module tag & determine module type
  var tagBuf: array[TAG_LEN + 1, uint8]
  copyMem(tagBuf.addr, buf[TAG_OFFSET].addr, TAG_LEN)
  tagBuf[TAG_LEN] = 0
  let tag = mkTag($cast[cstring](tagBuf[0].addr))

  (module.moduleType, module.numChannels) = determineModuleType(tag)

  # read song title
  var songTitle = cast[cstring](alloc0(MAX_SONG_TITLE_LEN + 1))
  copyMem(songTitle, buf[pos].addr, MAX_SONG_TITLE_LEN)
  module.songtitle = $songTitle
  pos += MAX_SONG_TITLE_LEN

  # load samples
  for i in 0..<MAX_SAMPLES:
    module.samples[i] = loadSample(buf, pos)

  # read song length
  module.songLength = int(buf[pos])
  pos += 1

  # skip byte TODO ?
  pos += 1

  # read song positions
  copyMem(module.songPositions.addr, buf[pos].addr, MAX_PATTERNS)
  pos += MAX_PATTERNS + TAG_LEN

  # song length = the pattern with the highest number in the songpos table + 1
  var numPatterns = 0
  for sp in module.songPositions:
    numPatterns = max(sp.int, numPatterns)
  numPatterns += 1

  # load patterns
  for pattNum in 0..<numPatterns:
    module.patterns.add(
      loadPattern(buf, pos, module.numChannels))

  # load samples
  for sampNum in 0..<MAX_SAMPLES:
    let length = module.samples[sampNum].length
    if length > 0:
      var data = cast[SampleDataPtr](alloc(length))
      copyMem(data, buf[pos].addr, length)
      module.samples[sampNum].data = data
      pos += length

  result = module
