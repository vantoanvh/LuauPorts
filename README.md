# A collection of algorithms in other lang ported to Luau

## Compression
- **[LZAV 5.8](https://github.com/avaneev/lzav/blob/main/lzav.h)** in-memory data compression and decompression algorithms. ( data format 3 )
```luau
compress(src: buffer): buffer
decompress(src: buffer, dstlen: number): buffer
```
- **[rANS](https://github.com/rygorous/ryg_rans)** an "range" variant from the ANS ( Asymmetric Numeral Systems ) family, with non-standardized header.
```luau
compress(src: buffer): buffer
decompress(src: buffer): buffer
```
- **[Zlib](https://en.wikipedia.org/wiki/Zlib)** is a data format and a lossless data compression software library created by Jean-loup Gailly and Mark Adler.
```luau
Compress(input: buffer, level: number): buffer
Decompress(input: buffer): buffer

Deflate(input: buffer, level: number): buffer
Inflate(input: buffer): buffer
```
## Conversion
- **[Base85](https://en.wikipedia.org/wiki/Ascii85)** also called Acsii85, a binary-to-text encoding developed by Paul E.
```luau
Encode(Input: buffer): buffer
Decode(Input: buffer): buffer
```
- **Base93** a binary-to-text encoding that uses 93 printable characters, the readily compact form, non-standardized layout.
```luau
Encode(Input: buffer): buffer
Decode(Input: buffer): buffer
```
- **Base94** a binary-to-text encoding, most compact one for JSON, non-standardized layout.
```luau
Encode(Input: buffer): buffer
Decode(Input: buffer): buffer
```
---
## Decoder
- **[GIFs](https://en.wikipedia.org/wiki/Ascii85)** is a classic bitmap image format released on June 15, 1987.
```luau
DecodeGIF(Input: buffer): {
	Animated: boolean,
	Size: Vector2,
	RGBA8: buffer,
	Frame: buffer,
	AdvanceFrame: () -> (),
	Reset: () -> (),
	Finished: boolean,
	Delay: number
}
```
- **[JPEG](https://en.wikipedia.org/wiki/JPEG)** is a commonly used method of lossy compression for digital images.
```luau
DecodeJPEG(Input: buffer): {
	Size: Vector2,
	RGBA8: OutputBuffer
}
```
- **[PNG](https://en.wikipedia.org/wiki/PNG)** is a raster-graphics file format that supports lossless data compression.
```luau
DecodePNG(Input: buffer): {
	Animated: boolean,
	Size: Vector2,
	RGBA8: buffer,
	Frame: buffer,
	AdvanceFrame: () -> (),
	Reset: () -> (),
	Finished: boolean,
	Delay: number
}
```
