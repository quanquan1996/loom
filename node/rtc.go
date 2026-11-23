package main

import (
	"encoding/json"
	"errors"
	"log"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

// Peer-to-peer forwarding: the same TCP connection to a loopback port as
// forward.go, but carried over a WebRTC data channel straight to the browser
// instead of through loom, whenever the two can reach each other (on IPv6
// nearly always; on IPv4 when at most one side sits behind a strict NAT).
// Loom only passes the offer and answer, over the forward's own WebSocket.
//
//	loom → device: forward_rtc {id, port, data: offer SDP}, cancel {id}
//	device → loom: forward_rtc_answer {id, data: answer SDP}, forward_closed {id}, error {id, message}
//
// The rules are those of forward_open: only a port in forward_ports, only on
// 127.0.0.1. The data channel is DTLS-encrypted end to end, keyed by the
// fingerprints in the SDP that loom passed. A cancel from loom (the switch
// going off, the pane closing) ends it just as it ends a relayed forward.

// Public STUN servers, for this device to learn its address on the far side
// of its NAT. Without them only host candidates are offered, which is still
// enough on IPv6.
var stunServers = []string{
	"stun:stun.l.google.com:19302",
	"stun:stun.cloudflare.com:3478",
	"stun:stun.miwifi.com:3478",
}

const (
	// A browser that never opens the channel (it gave up and fell back).
	rtcOpenTimeout = 30 * time.Second
	// How long gathering candidates may take before answering with what we have.
	rtcGatherTimeout = 1500 * time.Millisecond
	// Data channel messages: small enough for every browser's SCTP stack.
	rtcChunk = 16 << 10
	// Stop reading the port while this much waits to be sent to the browser.
	rtcHighWater = 1 << 20
	rtcLowWater  = 256 << 10
)

type rtcForward struct {
	pc   *webrtc.PeerConnection
	once sync.Once
	done chan struct{}
}

func (f *rtcForward) close() {
	f.once.Do(func() {
		close(f.done)
		// Not inline: this may run inside one of pion's own callbacks,
		// and Close waits for those.
		go f.pc.Close()
	})
}

func (s *session) forwardRTC(r request) {
	if !s.forwardAllowed(r.Port) {
		s.fail(r.ID, errors.New("port "+strconv.Itoa(r.Port)+" is not forwarded on this device (forward_ports in its loom-node config)"))
		return
	}
	var offer webrtc.SessionDescription
	if err := json.Unmarshal([]byte(r.Data), &offer); err != nil {
		offer = webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: r.Data}
	}

	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{{URLs: stunServers}},
	})
	if err != nil {
		s.fail(r.ID, err)
		return
	}
	f := &rtcForward{pc: pc, done: make(chan struct{})}
	s.mu.Lock()
	if old := s.rtcs[r.ID]; old != nil {
		old.close()
	}
	s.rtcs[r.ID] = f
	s.mu.Unlock()

	end := func(why string) {
		s.mu.Lock()
		if s.rtcs[r.ID] == f {
			delete(s.rtcs, r.ID)
		}
		s.mu.Unlock()
		select {
		case <-f.done:
			return
		default:
		}
		f.close()
		audit("forward %s rtc closed (%s)", r.ID, why)
		s.c.push(s.ctx, "forward_closed", map[string]any{"id": r.ID})
	}

	opened := make(chan struct{})
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		dc.OnOpen(func() {
			select {
			case <-opened:
				dc.Close() // one channel per forward
				return
			default:
				close(opened)
			}
			s.rtcPipe(r, f, dc, end)
		})
	})
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		if st == webrtc.PeerConnectionStateFailed || st == webrtc.PeerConnectionStateClosed {
			end("peer " + st.String())
		}
	})

	if err := pc.SetRemoteDescription(offer); err != nil {
		end("bad offer")
		s.fail(r.ID, err)
		return
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		end("no answer")
		s.fail(r.ID, err)
		return
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		end("no answer")
		s.fail(r.ID, err)
		return
	}
	select {
	case <-gathered:
	case <-time.After(rtcGatherTimeout):
	}
	sdp, _ := json.Marshal(pc.LocalDescription())
	s.c.push(s.ctx, "forward_rtc_answer", map[string]any{"id": r.ID, "data": string(sdp)})

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		select {
		case <-opened:
		case <-f.done:
		case <-s.ctx.Done():
			end("connection lost")
		case <-time.After(rtcOpenTimeout):
			end("never opened")
		}
	}()
}

// The data channel is open: dial the port and pass bytes both ways.
func (s *session) rtcPipe(r request, f *rtcForward, dc *webrtc.DataChannel, end func(string)) {
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(r.Port))
	c, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		log.Printf("forward %s: %v", r.ID, err)
		end("port closed")
		return
	}
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
	if sel, err := f.pc.SCTP().Transport().ICETransport().GetSelectedCandidatePair(); err == nil && sel != nil {
		audit("forward %s rtc open %s via %s", r.ID, addr, sel.String())
	} else {
		audit("forward %s rtc open %s", r.ID, addr)
	}

	go func() {
		<-f.done
		c.Close()
	}()

	// Browser → port. pion calls this from one goroutine, in order.
	dc.OnMessage(func(m webrtc.DataChannelMessage) {
		if _, err := c.Write(m.Data); err != nil {
			end("port write failed")
		}
	})
	dc.OnClose(func() { end("browser closed") })

	// Port → browser, pausing while the channel's send buffer is full.
	drained := make(chan struct{}, 1)
	dc.SetBufferedAmountLowThreshold(rtcLowWater)
	dc.OnBufferedAmountLow(func() {
		select {
		case drained <- struct{}{}:
		default:
		}
	})
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		buf := make([]byte, rtcChunk)
		for {
			n, err := c.Read(buf)
			if n > 0 {
				if dc.Send(append([]byte(nil), buf[:n]...)) != nil {
					break
				}
				for dc.BufferedAmount() > rtcHighWater {
					select {
					case <-drained:
					case <-f.done:
						return
					case <-time.After(time.Second):
					}
				}
			}
			if err != nil {
				break
			}
		}
		end("port closed")
	}()
}
