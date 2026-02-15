# <p align="center">tozi</p>

<p align="center">
  Torrent downloader or leecher.<br>
  <sub align="center">pronounced as TOZ-ee</sub>
</p>

## Usage

```
tozi download|continue|verify|info ./path/to/file.torrent
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
- there is no linux support, because I didn't write `epoll` wrapper and I didn't use pre-built libraries.
- ~~file read/writes are "blocking". I think i will change this with zig `0.16.0`. But to be honest, I didn't find it to be a bottleneck, because usually the network is saturated first.~~ File and hashing are now done in separate threads. It turned out to be easier than i expected. Also discovered new thing `std.posix.pipe` for threads communications. It integrated nicely with kqueue.
- udp tracker support. Learned that udp is also quite cool, because you receive either **whole**
    packet or nothing, which is perfect for torrent tracker.

## Support

- BEP-003: Core protocol (I'm not entierly sure this is 100% compliant, but it still downloads torrents)
- BEP-006: Fast extension
- BEP-010: Extension Protocol
- BEP-012: Multiple trackers
- BEP-015: UDP Tracker Protocol for BitTorrent (TODO: add reties)
- BEP-020: Peer ID Conventions
- BEP-023: Tracker Returns Compact Peer Lists
