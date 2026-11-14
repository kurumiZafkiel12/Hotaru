package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
)

const maxControlFrame = 16 * 1024 * 1024
const bootstrapProtocol = "hotaru-bootstrap-v1"

type bootstrap struct {
	Protocol string          `json:"protocol"`
	Config   json.RawMessage `json:"config"`
}

func readFrame(input io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(input, header[:]); err != nil {
		return nil, err
	}
	size := binary.LittleEndian.Uint32(header[:])
	if size == 0 || size > maxControlFrame {
		return nil, errors.New("invalid host control frame size")
	}
	payload := make([]byte, int(size))
	_, err := io.ReadFull(input, payload)
	return payload, err
}

type frameWriter struct{ io.Writer }

func (w frameWriter) Write(payload []byte) (int, error) {
	if len(payload) == 0 || len(payload) > maxControlFrame {
		return 0, errors.New("invalid host control frame size")
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := io.Copy(w.Writer, bytes.NewReader(header[:])); err != nil {
		return 0, err
	}
	n, err := io.Copy(w.Writer, bytes.NewReader(payload))
	return int(n), err
}

type frameReader struct {
	input   io.Reader
	pending *bytes.Reader
}

func (r *frameReader) Read(output []byte) (int, error) {
	if len(output) == 0 {
		return 0, nil
	}
	if r.pending == nil || r.pending.Len() == 0 {
		payload, err := readFrame(r.input)
		if err != nil {
			return 0, err
		}
		r.pending = bytes.NewReader(payload)
	}
	return r.pending.Read(output)
}

func readBootstrap(input io.Reader) ([]byte, error) {
	payload, err := readFrame(input)
	if err != nil {
		return nil, err
	}
	var request bootstrap
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&request); err != nil {
		return nil, err
	}
	if decoder.Decode(new(any)) != io.EOF || request.Protocol != bootstrapProtocol ||
		len(request.Config) == 0 || request.Config[0] != '{' {
		return nil, errors.New("invalid host bootstrap")
	}
	return request.Config, nil
}

func serveFramed(ctx context.Context, config []byte, stream io.ReadWriter, create func(context.Context, []byte) (engine, error)) error {
	return serve(ctx, "", &frameReader{input: stream}, frameWriter{stream},
		func(ctx context.Context, _ string) (engine, error) { return create(ctx, config) })
}
