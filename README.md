# A collection of algorithms in other lang ported to Luau

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

# Future collections
In the future, I could add like Ported Luau Parser 7.03 (rewritten), or LZ4 (collected in llz4), Base94 and Base85 (collected in devforum)
