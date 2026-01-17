# <p align="center">tozi</p>

<p align="center">
  Torrent downloader or leecher.<br>
  <sub align="center">pronounced as TOZ-ee</sub>
</p>

## Usage

```
tozi download|continue ./path/to/file.torrent
```

## Building

```
zig build
```

## Why ?

- learn kqueue, torrent proto and zig
- replace motrix
- fast
- mine (?)

## Notes

- there is no `seeding` capability, because almost nobody would have a server that is available to the public web. This means nobody can connect to you (unless you messed with your network setup, which I didn't do).
- there is no linux support, because I didn't write `epoll` wrapper and I didn't use pre-built libraries
- file read/writes are "blocking". I think i will change this with zig `0.16.0`. But to be honest, I didn't find it to be a bottleneck, because usually the network is saturated first.
