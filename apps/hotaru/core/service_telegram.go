package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"time"
)

var telegramDCs = []string{
	"149.154.175.50:443", "149.154.167.51:443", "149.154.175.100:443",
	"149.154.167.91:443", "91.108.56.130:443",
}

func checkTelegram(env serviceEnv) ServiceCheckItem {
	item := classifyServiceEndpoint(env.get("https://web.telegram.org/", serviceHtmlMaxBody))
	passed := 0
	for index, address := range telegramDCs {
		if env.ctx.Err() != nil {
			break
		}
		if telegramDCProbe(env, index+1, address) == nil {
			passed++
		}
	}
	if passed == len(telegramDCs) {
		item.Status = serviceReachable
	} else if passed > 0 {
		item.Status = serviceInconclusive
	} else if item.Status == serviceReachable {
		item.Status = serviceInconclusive
	}
	return item
}

func telegramDCProbe(env serviceEnv, dc int, address string) (err error) {
	ctx, cancel := context.WithTimeout(env.ctx, env.timeout)
	defer cancel()
	dialer := &probeDialer{}
	observation := ServiceObservation{URL: fmt.Sprintf("mtproto://%s/DC%d", address, dc)}
	defer func() {
		env.hits.add(dialer.hits(env.proxyName))
		if route := dialer.route(); route != nil {
			observation.Chains, observation.Rule, observation.RulePayload = route.chains, route.rule, route.rulePayload
		}
		if err != nil {
			observation.Error = err.Error()
		}
		if env.observations != nil {
			*env.observations = append(*env.observations, observation)
		}
	}()
	if env.proxyName != "" {
		dialer.proxy = lookupProxy(env.proxyName)
		if dialer.proxy == nil {
			return fmt.Errorf("proxy %q is not part of the applied config", env.proxyName)
		}
	}
	if !probeSlots.acquireWithin(ctx, env.timeout) {
		return context.DeadlineExceeded
	}
	defer probeSlots.release()
	conn, err := dialer.dial(ctx, "tcp", address)
	if err != nil {
		return err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	return telegramHandshake(conn)
}

func telegramHandshake(conn net.Conn) error {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return err
	}
	request := make([]byte, 42)
	request[0], request[1] = 0xef, 10
	binary.LittleEndian.PutUint64(request[10:], uint64(time.Now().Unix())<<32)
	binary.LittleEndian.PutUint32(request[18:], 20)
	binary.LittleEndian.PutUint32(request[22:], 0xbe7e8ef1)
	copy(request[26:], nonce[:])
	if _, err := io.Copy(conn, bytes.NewReader(request)); err != nil {
		return err
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(conn, header[:1]); err != nil {
		return err
	}
	words := int(header[0])
	if words == 0x7f {
		if _, err := io.ReadFull(conn, header[:3]); err != nil {
			return err
		}
		words = int(header[0]) | int(header[1])<<8 | int(header[2])<<16
	}
	if words < 14 || words > 1024 {
		return fmt.Errorf("invalid MTProto frame length: %d", words)
	}
	response := make([]byte, words*4)
	if _, err := io.ReadFull(conn, response); err != nil {
		return err
	}
	if binary.LittleEndian.Uint64(response) != 0 ||
		int(binary.LittleEndian.Uint32(response[16:])) != len(response)-20 ||
		binary.LittleEndian.Uint32(response[20:]) != 0x05162463 ||
		!bytes.Equal(response[24:40], nonce[:]) {
		return fmt.Errorf("MTProto resPQ did not match the request")
	}
	return nil
}
