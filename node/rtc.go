package main

import (
	"encoding/json"
	"errors"
	"log"
	"net"
	"strconv"
	"strings"
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
	// After the first server-reflexive candidate, how long to wait for more.
	rtcGatherGrace = 300 * time.Millisecond
	// Data channel messages: small enough for every browser's SCTP stack.
	rtcChunk = 16 << 10
	// Stop reading the port while this much waits to be sent to the browser.
	rtcHighWater = 1 << 20
	rtcLowWater  = 256 << 10
	// How many ports past the highest one STUN saw to offer as guesses.
	rtcPredict = 64
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
	// A STUN server that never answers (Google's, from China) would hold the
	// answer for the whole timeout; once one has given our public address,
	// the others get a moment more.
	reflexive := make(chan struct{}, 1)
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil && c.Typ == webrtc.ICECandidateTypeSrflx {
			select {
			case reflexive <- struct{}{}:
			default:
			}
		}
	})
	if err := pc.SetLocalDescription(answer); err != nil {
		end("no answer")
		s.fail(r.ID, err)
		return
	}
	deadline := time.After(rtcGatherTimeout)
	select {
	case <-gathered:
	case <-deadline:
	case <-reflexive:
		select {
		case <-gathered:
		case <-deadline:
		case <-time.After(rtcGatherGrace):
		}
	}
	local := *pc.LocalDescription()
	local.SDP = predictPorts(local.SDP, rtcPredict)
	sdp, _ := json.Marshal(local)
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

// predictPorts adds guessed server-reflexive candidates to an answer, for a
// device behind a NAT that hands out a new public port for every destination
// (symmetric, as carrier-grade NATs often are). STUN then sees one port, and
// the browser a different one, a little higher; a browser behind a NAT that
// only lets in replies from ports it sent to never lets ours in. Offering the
// next ports too makes the browser send checks to them, which opens its NAT to
// the port ours really uses toward it; ICE takes it from there (the reply, or
// our own check arriving as a peer-reflexive candidate). Guesses that miss
// are a few dropped packets. When every STUN server saw the same port the
// NAT keeps ports, the real candidate is right, and nothing is added.
func predictPorts(sdp string, n int) string {
	type seen struct {
		min, max, count int
		prio            uint64
	}
	refl := map[string]*seen{}
	var order []string
	lines := strings.Split(sdp, "\r\n")
	last := -1
	for i, l := range lines {
		f := strings.Fields(strings.TrimPrefix(l, "a=candidate:"))
		if !strings.HasPrefix(l, "a=candidate:") || len(f) < 8 {
			continue
		}
		last = i
		if strings.ToLower(f[2]) != "udp" || f[7] != "srflx" || strings.Contains(f[4], ":") {
			continue
		}
		port, err1 := strconv.Atoi(f[5])
		prio, err2 := strconv.ParseUint(f[3], 10, 32)
		if err1 != nil || err2 != nil {
			continue
		}
		r := refl[f[4]]
		if r == nil {
			r = &seen{min: port, max: port, prio: prio}
			refl[f[4]] = r
			order = append(order, f[4])
		}
		r.count++
		r.min, r.max = min(r.min, port), max(r.max, port)
		r.prio = min(r.prio, prio)
	}
	if last < 0 {
		return sdp
	}
	var add []string
	for _, ip := range order {
		r := refl[ip]
		if r.count > 1 && r.min == r.max {
			continue
		}
		for k := 1; k <= n && r.max+k <= 65535; k++ {
			add = append(add, "a=candidate:pp"+strconv.Itoa(k)+" 1 udp "+
				strconv.FormatUint(r.prio-uint64(k), 10)+" "+ip+" "+strconv.Itoa(r.max+k)+
				" typ srflx raddr 0.0.0.0 rport 0")
		}
	}
	if len(add) == 0 {
		return sdp
	}
	out := append(append(append([]string{}, lines[:last+1]...), add...), lines[last+1:]...)
	return strings.Join(out, "\r\n")
}
