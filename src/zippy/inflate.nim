import bitstreams, common, zippyerror

const
  huffmanChunkBits = 9
  huffmanNumChunks = 1 shl huffmanChunkBits
  huffmanCountMask = 15
  huffmanValueShift = 4

type
  Huffman = object
    minCodeLength, maxCodeLength: uint8
    chunks: array[huffmanNumChunks, uint16]
    links: seq[array[64, uint16]]
    linkMask: uint16

when defined(release):
  {.push checks: off.}

func initHuffman(lengths: seq[uint8], maxCodes: int): Huffman =
  ## See https://raw.githubusercontent.com/madler/zlib/master/doc/algorithm.txt

  var
    counts: array[maxCodeLength + 1, uint16]
    numCodes: int

  result.minCodeLength = uint8.high

  for _, n in lengths:
    if n == 0:
      continue
    inc counts[n]
    inc numCodes
    result.minCodeLength = min(n, result.minCodeLength)
    result.maxCodeLength = max(n, result.maxCodeLength)

  if result.maxCodeLength == 0 or
    result.maxCodeLength > maxCodeLength or
    numCodes > maxCodes:
    failUncompress()

  var
    code: uint16
    nextCode: array[maxCodeLength + 1, uint16]
  for i in result.minCodeLength .. result.maxCodeLength:
    code = code shl 1
    nextCode[i] = code
    code += counts[i]

  # if code != (1.uint16 shl result.maxCodeLength) and
  #   not (code == 1 and result.maxCodeLength == 1):
  #   debugEcho code, " ", result.maxCodeLength, " ", result.minCodeLength
  #   failUncompress()

  if result.maxCodeLength > huffmanChunkBits:
    let numLinks = 1.uint16 shl (result.maxCodeLength - huffmanChunkBits)
    result.linkMask = numLinks - 1

    let link = nextCode[huffmanChunkBits + 1] shr 1
    result.links.setLen(huffmanNumChunks - link)
    for i in link ..< huffmanNumChunks:
      let
        reverse = reverseUint16(i.uint16, huffmanChunkBits)
        offset = i - link
      when not defined(release):
        if result.chunks[reverse] != 0:
          raise newException(ZippyError, "Overwriting chunk")
      result.chunks[reverse] = (
        (offset shl huffmanValueShift) or huffmanChunkBits + 1
      ).uint16
      # result.links[offset].setLen(numLinks)

  for i, n in lengths:
    if n == 0:
      continue

    let
      code = nextCode[n]
      chunk = (i.uint16 shl huffmanValueShift) or n
      reverse = reverseUint16(code, n)
    inc nextCode[n]
    if n <= huffmanChunkBits:
      for offset in countup(reverse.int, result.chunks.high, 1 shl n):
        when not defined(release):
          if result.chunks[offset] != 0:
            raise newException(ZippyError, "Overwriting chunk")
        result.chunks[offset] = chunk
    else:
      let
        j = reverse and (huffmanNumChunks - 1)
        value = result.chunks[j] shr huffmanValueShift
        reverseShifted = reverse shr huffmanChunkBits
      when not defined(release):
        if (result.chunks[j] and huffmanCountMask) != huffmanChunkBits + 1:
          raise newException(ZippyError, "Not an indirect chunk")
      for offset in countup(
        reverseShifted.int,
        result.links[value].high,
        1 shl (n - huffmanChunkBits)
      ):
        when not defined(release):
          if result.links[value][offset] != 0:
            raise newException(ZippyError, "Overwriting chunk")
        result.links[value][offset] = chunk

  # when not defined(release):
  #   for i, chunk in result.chunks:
  #     if chunk == 0:
  #       if code == 1 and i mod 2 == 1:
  #         continue
  #       raise newException(ZippyError, "Missing chunk")

  #   for i in 0 ..< result.links.len:
  #     for _, chunk in result.links[i]:
  #       if chunk == 0:
  #         raise newException(ZippyError, "Missing chunk")

func decodeSymbol(b: var BitStream, h: Huffman): uint16 {.inline.} =
  ## See https://raw.githubusercontent.com/madler/zlib/master/doc/algorithm.txt
  ## This function is the most important for inflate performance.

  b.checkBytePos()

  var
    bits = b.data[b.bytePos].uint16 shr b.bitPos
    numBits = 8 - b.bitPos

  # Fill bits up since we know codes must be between 1 and 15 bits long
  if b.bytePos + 1 < b.data.len:
    bits = bits or (b.data[b.bytePos + 1].uint16 shl numBits)
  if b.bytePos + 2 < b.data.len:
    bits = bits or (b.data[b.bytePos + 2].uint16 shl (numBits + 8))

  numBits = 15

  var
    chunk = h.chunks[bits and (huffmanNumChunks - 1)]
    n = (chunk and huffmanCountMask).int
  if n > huffmanChunkBits:
    chunk = h.links[
      chunk shr huffmanValueShift][(bits shr huffmanChunkBits) and h.linkMask
    ]
    n = (chunk and huffmanCountMask).int

  if n == 0 or n > numBits:
    failUncompress()

  inc(b.bytePos, (n + b.bitPos) shr 3)
  b.bitPos = (n + b.bitPos) and 7

  chunk shr huffmanValueShift

func inflateBlock(b: var BitStream, dst: var seq[uint8], fixedCodes: bool) =
  var literalHuffman, distanceHuffman: Huffman

  if fixedCodes:
    literalHuffman = initHuffman(fixedCodeLengths, maxFixedLitLenCodes)
    distanceHuffman = initHuffman(fixedDistanceLengths, maxDistCodes)
  else:
    let
      hlit = b.readBits(5).int + firstLengthCodeIndex
      hdist = b.readBits(5).int + 1
      hclen = b.readBits(4).int + 4

    var clCodeLengths = newSeq[uint8](19)
    for i in 0 ..< hclen.int:
      clCodeLengths[clclOrder[i]] = b.readBits(3).uint8

    let h = initHuffman(clCodeLengths, 19)

    var unpacked: seq[uint8]
    while unpacked.len < hlit + hdist:
      let symbol = decodeSymbol(b, h)
      if symbol <= 15:
        unpacked.add(symbol.uint8)
      elif symbol == 16:
        if unpacked.len == 0:
          failUncompress()
        let prev = unpacked[unpacked.len - 1]
        for i in 0 ..< b.readBits(2).int + 3:
          unpacked.add(prev)
      elif symbol == 17:
        unpacked.setLen(unpacked.len + b.readBits(3).int + 3)
      elif symbol == 18:
        unpacked.setLen(unpacked.len + b.readBits(7).int + 11)
      else:
        raise newException(ZippyError, "Invalid symbol")

    literalHuffman = initHuffman(unpacked[0 ..< hlit], maxLitLenCodes)
    distanceHuffman = initHuffman(unpacked[hlit ..< unpacked.len], maxDistCodes)

  var op = dst.len
  while true:
    let symbol = decodeSymbol(b, literalHuffman)
    if symbol <= 255:
      if op >= dst.len:
        dst.setLen((op + 1) * 2)
      dst[op] = symbol.uint8
      inc op
    elif symbol == 256:
      break
    else:
      let lengthIndex = symbol - firstLengthCodeIndex
      if lengthIndex >= baseLengths.len:
        failUncompress()

      let totalLength = (
        baseLengths[lengthIndex] +
        b.readBits(baseLengthsExtraBits[lengthIndex])
      ).int

      let distIndex = decodeSymbol(b, distanceHuffman)
      if distIndex >= baseDistances.len:
        failUncompress()

      let totalDist = (
        baseDistances[distIndex] +
        b.readBits(baseDistanceExtraBits[distIndex])
      ).int
      if totalDist > op:
        failUncompress()

      # Min match is 3 so leave room to overwrite by 13
      if op + totalLength + 13 > dst.len:
        dst.setLen((op + totalLength) * 2 + 10)

      if totalLength <= 16 and totalDist >= 8 and dst.len > op + 16:
        copy64(dst, dst, op, op - totalDist)
        copy64(dst, dst, op + 8, op - totalDist + 8)
        inc(op, totalLength)
      elif dst.len - op >= totalLength + 10:
        var
          src = op - totalDist
          pos = op
          remaining = totalLength
        while pos - src < 8:
          copy64(dst, dst, pos, src)
          dec(remaining, pos - src)
          inc(pos, pos - src)
        while remaining > 0:
          copy64(dst, dst, pos, src)
          inc(src, 8)
          inc(pos, 8)
          dec(remaining, 8)
        inc(op, totalLength)
      else:
        for i in op ..< op + totalLength:
          dst[op] = dst[op - totalDist]
          inc op

  dst.setLen(op)

func inflateNoCompression(b: var BitStream, dst: var seq[uint8]) =
  b.skipRemainingBitsInCurrentByte()
  let
    len = b.readBits(16).int
    nlen = b.readBits(16).int
  if len + nlen != 65535:
    failUncompress()
  if len > 0:
    let pos = dst.len
    dst.setLen(pos + len) # Make room for the bytes to be copied to
    b.readBytes(dst, pos, len)

func inflate*(dst: var seq[uint8], src: seq[uint8]) =
  var
    b = initBitStream(src)
    finalBlock: bool
  while not finalBlock:
    let
      bfinal = b.readBits(1)
      btype = b.readBits(2)
    if bfinal > 0:
      finalBlock = true

    case btype:
    of 0: # No compression
      inflateNoCompression(b, dst)
    of 1: # Compressed with fixed Huffman codes
      inflateBlock(b, dst, true)
    of 2: # Compressed with dynamic Huffman codes
      inflateBlock(b, dst, false)
    else:
      raise newException(ZippyError, "Invalid block header")

func inflate*(src: seq[uint8]): seq[uint8] =
  result = newSeqOfCap[uint8](src.len)
  inflate(result, src)

when defined(release):
  {.pop.}
