package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
)

const protocolVersion = 4

// Frame types (packages/intercom_core/lib/src/protocol.dart).
const (
	tHello       = 0x01
	tOpen        = 0x02
	tClose       = 0x03
	tReject      = 0x06
	tPing        = 0x08
	tPong        = 0x09
	tTunnelOpen  = 0x12
	tTunnelReply = 0x13
	tTunnelData  = 0x14
	tTunnelClose = 0x15
	tKey         = 0x10
	tSealed      = 0x11
)

const maxFramePayload = 256 * 1024

type frame struct {
	typ     byte
	payload []byte
}

func (f frame) encode() []byte {
	out := make([]byte, 5+len(f.payload))
	out[0] = f.typ
	binary.BigEndian.PutUint32(out[1:5], uint32(len(f.payload)))
	copy(out[5:], f.payload)
	return out
}

func jsonFrame(typ byte, v any) frame {
	b, _ := json.Marshal(v)
	return frame{typ, b}
}

type frameDecoder struct{ buf []byte }

func (d *frameDecoder) add(chunk []byte) ([]frame, error) {
	d.buf = append(d.buf, chunk...)
	var out []frame
	for len(d.buf) >= 5 {
		n := binary.BigEndian.Uint32(d.buf[1:5])
		if n > maxFramePayload {
			return nil, errors.New("frame too large")
		}
		if uint32(len(d.buf)-5) < n {
			break
		}
		p := make([]byte, n)
		copy(p, d.buf[5:5+n])
		out = append(out, frame{d.buf[0], p})
		d.buf = d.buf[5+n:]
	}
	if len(d.buf) == 0 {
		d.buf = nil
	}
	return out, nil
}
