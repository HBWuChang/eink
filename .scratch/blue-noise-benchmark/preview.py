import pathlib, struct, zlib
p=pathlib.Path(__file__).parent
raw=(p/'blue-noise-768x552.pgm').read_bytes().split(b'\n',3)[3]
w,h=768,552
values=struct.unpack('>'+str(w*h)+'H', raw)
def png(name, pixels):
 def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
 scan=b''.join(b'\0'+pixels[y*w:(y+1)*w] for y in range(h))
 (p/name).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,0,0,0,0))+chunk(b'IDAT',zlib.compress(scan))+chunk(b'IEND',b''))
png('blue-noise-768x552.png',bytes(v>>8 for v in values))
png('threshold-slices.png',bytes(255 if v < [16384,32768,49152][min(2,(i%w)//256)] else 0 for i,v in enumerate(values)))
for t in (0.1,0.25,0.5,0.75,0.9):
 actual=sum(v<t*65536 for v in values)/len(values)
 print(f'threshold={t:.2f} white_fraction={actual:.6f}')
