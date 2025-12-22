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
### Note
In the future, I could add like Ported Luau Parser 7.03 (rewritten), LZAV HI, or tANS.
