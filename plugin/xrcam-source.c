/*
 * xrcam-source: native OBS source for the XRCam USB stream.
 *
 * Exists because the stock Media Source held ~500ms even after every knob
 * was verified applied (nobuffer, wallclock PTS, unbuffered async, and a
 * Constrained Baseline stream measured arriving at a clean 33ms cadence).
 * This bypasses ffmpeg's demux/media-playback pipeline entirely:
 *
 *   TCP (iproxy) -> split Annex-B on the app's AUDs -> Windows Media
 *   Foundation H.264 decoder (MF_LOW_LATENCY) -> obs_source_output_video()
 *
 * The frame that arrives is the frame OBS composites. No container, no
 * probe, no clock: the phone already paces frames at 30fps and the AUD
 * marks each boundary, so nothing here ever waits on a timestamp.
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <initguid.h>   /* materialize DEFINE_GUIDs below */
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <wmcodecdsp.h> /* CLSID_CMSH264DecoderMFT */

#include <obs-module.h>
#include <util/platform.h>
#include <media-io/video-io.h>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "wmcodecdspuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "ws2_32.lib")

OBS_DECLARE_MODULE()

#define XR_LOG(level, fmt, ...) \
	blog(level, "[xrcam-source] " fmt, ##__VA_ARGS__)

/* Frame boundary marker the app emits before every access unit. */
static const uint8_t AUD[5] = {0x00, 0x00, 0x00, 0x01, 0x09};

/* Growable receive buffer; reset if a malformed stream lets it run away. */
#define RECV_CHUNK   (256 * 1024)
#define MAX_PENDING  (16 * 1024 * 1024)

struct xrcam_src {
	obs_source_t *source;

	/* settings (written by update(), read by the worker) */
	CRITICAL_SECTION lock;
	char host[128];
	int port;

	/* worker thread */
	HANDLE thread;
	volatile LONG stop;
	volatile SOCKET sock; /* closed from destroy()/update() to unblock recv */

	/* decoder state (worker thread only) */
	IMFTransform *mft;
	BOOL mft_streaming;
	UINT32 coded_w, coded_h;    /* surface size, e.g. 1920x1088 */
	UINT32 disp_w, disp_h;      /* picture size, e.g. 1920x1080 */
	LONG stride;
	LONGLONG pts;               /* synthetic input timestamps, 100ns */
};

/* ---------------------------------------------------------------- decoder */

static void decoder_destroy(struct xrcam_src *s)
{
	if (s->mft) {
		IMFTransform_Release(s->mft);
		s->mft = NULL;
	}
	s->mft_streaming = FALSE;
	s->coded_w = s->coded_h = s->disp_w = s->disp_h = 0;
}

static HRESULT decoder_negotiate_output(struct xrcam_src *s)
{
	IMFMediaType *type = NULL;
	HRESULT hr = E_FAIL;

	for (DWORD i = 0;; i++) {
		hr = IMFTransform_GetOutputAvailableType(s->mft, 0, i, &type);
		if (FAILED(hr))
			return hr;

		GUID sub;
		if (SUCCEEDED(IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &sub)) &&
		    IsEqualGUID(&sub, &MFVideoFormat_NV12))
			break;

		IMFMediaType_Release(type);
		type = NULL;
	}

	hr = IMFTransform_SetOutputType(s->mft, 0, type, 0);
	if (FAILED(hr)) {
		IMFMediaType_Release(type);
		return hr;
	}

	UINT64 size = 0;
	if (SUCCEEDED(IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &size))) {
		s->coded_w = (UINT32)(size >> 32);
		s->coded_h = (UINT32)(size & 0xffffffff);
	}

	/* Coded size may exceed the picture (1080 lines code as 1088); the
	 * aperture carries the real display rectangle. */
	s->disp_w = s->coded_w;
	s->disp_h = s->coded_h;
	MFVideoArea area;
	if (SUCCEEDED(IMFMediaType_GetBlob(type, &MF_MT_MINIMUM_DISPLAY_APERTURE,
	                                   (UINT8 *)&area, sizeof(area), NULL))) {
		if (area.Area.cx > 0 && area.Area.cy > 0) {
			s->disp_w = (UINT32)area.Area.cx;
			s->disp_h = (UINT32)area.Area.cy;
		}
	}

	UINT32 stride = 0;
	if (SUCCEEDED(IMFMediaType_GetUINT32(type, &MF_MT_DEFAULT_STRIDE, &stride)) &&
	    (LONG)stride > 0)
		s->stride = (LONG)stride;
	else
		s->stride = (LONG)s->coded_w;

	IMFMediaType_Release(type);

	XR_LOG(LOG_INFO, "decoder output: %ux%u (coded %ux%u), stride %ld",
	       s->disp_w, s->disp_h, s->coded_w, s->coded_h, s->stride);
	return S_OK;
}

static HRESULT decoder_create(struct xrcam_src *s)
{
	decoder_destroy(s);

	HRESULT hr = CoCreateInstance(&CLSID_CMSH264DecoderMFT, NULL,
	                              CLSCTX_INPROC_SERVER, &IID_IMFTransform,
	                              (void **)&s->mft);
	if (FAILED(hr)) {
		XR_LOG(LOG_ERROR, "H.264 MFT create failed (0x%08lx)", hr);
		return hr;
	}

	/* Emit each picture as soon as it decodes instead of batching. */
	IMFAttributes *attrs = NULL;
	if (SUCCEEDED(IMFTransform_GetAttributes(s->mft, &attrs))) {
		IMFAttributes_SetUINT32(attrs, &MF_LOW_LATENCY, TRUE);
		IMFAttributes_Release(attrs);
	}

	IMFMediaType *in = NULL;
	hr = MFCreateMediaType(&in);
	if (FAILED(hr))
		return hr;
	IMFMediaType_SetGUID(in, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
	IMFMediaType_SetGUID(in, &MF_MT_SUBTYPE, &MFVideoFormat_H264);
	hr = IMFTransform_SetInputType(s->mft, 0, in, 0);
	IMFMediaType_Release(in);
	if (FAILED(hr)) {
		XR_LOG(LOG_ERROR, "SetInputType failed (0x%08lx)", hr);
		return hr;
	}

	/* Output type becomes available once the SPS has been seen; a
	 * STREAM_CHANGE from ProcessOutput finishes the negotiation. */
	decoder_negotiate_output(s);

	IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
	IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
	s->mft_streaming = TRUE;
	s->pts = 0;
	return S_OK;
}

static void output_frame(struct xrcam_src *s, IMFSample *sample)
{
	IMFMediaBuffer *buf = NULL;
	if (FAILED(IMFSample_ConvertToContiguousBuffer(sample, &buf)))
		return;

	BYTE *scan0 = NULL;
	LONG pitch = s->stride;
	BOOL locked2d = FALSE;

	IMF2DBuffer *b2d = NULL;
	if (SUCCEEDED(IMFMediaBuffer_QueryInterface(buf, &IID_IMF2DBuffer,
	                                            (void **)&b2d))) {
		if (SUCCEEDED(IMF2DBuffer_Lock2D(b2d, &scan0, &pitch)))
			locked2d = TRUE;
		else {
			IMF2DBuffer_Release(b2d);
			b2d = NULL;
		}
	}

	DWORD len = 0;
	if (!locked2d) {
		DWORD max = 0;
		if (FAILED(IMFMediaBuffer_Lock(buf, &scan0, &max, &len))) {
			IMFMediaBuffer_Release(buf);
			return;
		}
	}

	if (scan0 && s->disp_w && s->disp_h && pitch > 0) {
		struct obs_source_frame frame = {0};
		frame.format = VIDEO_FORMAT_NV12;
		frame.width = s->disp_w;
		frame.height = s->disp_h;
		frame.data[0] = scan0;
		frame.linesize[0] = (uint32_t)pitch;
		/* UV plane sits below the full coded-height Y plane. */
		frame.data[1] = scan0 + (size_t)pitch * s->coded_h;
		frame.linesize[1] = (uint32_t)pitch;
		frame.timestamp = os_gettime_ns();
		video_format_get_parameters(VIDEO_CS_709, VIDEO_RANGE_PARTIAL,
		                            frame.color_matrix,
		                            frame.color_range_min,
		                            frame.color_range_max);
		obs_source_output_video(s->source, &frame);
	}

	if (locked2d) {
		IMF2DBuffer_Unlock2D(b2d);
		IMF2DBuffer_Release(b2d);
	} else {
		IMFMediaBuffer_Unlock(buf);
	}
	IMFMediaBuffer_Release(buf);
}

static HRESULT drain_outputs(struct xrcam_src *s)
{
	for (;;) {
		MFT_OUTPUT_STREAM_INFO osi = {0};
		IMFTransform_GetOutputStreamInfo(s->mft, 0, &osi);

		MFT_OUTPUT_DATA_BUFFER out = {0};
		IMFSample *osample = NULL;

		BOOL provides = (osi.dwFlags &
		                 (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
		                  MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
		if (!provides) {
			DWORD cb = osi.cbSize;
			if (cb == 0)
				cb = s->coded_w * s->coded_h * 3 / 2 + 4096;
			IMFMediaBuffer *ob = NULL;
			if (FAILED(MFCreateSample(&osample)))
				return E_OUTOFMEMORY;
			if (FAILED(MFCreateMemoryBuffer(cb, &ob))) {
				IMFSample_Release(osample);
				return E_OUTOFMEMORY;
			}
			IMFSample_AddBuffer(osample, ob);
			IMFMediaBuffer_Release(ob);
			out.pSample = osample;
		}

		DWORD status = 0;
		HRESULT hr = IMFTransform_ProcessOutput(s->mft, 0, 1, &out, &status);

		if (out.pEvents)
			IMFCollection_Release(out.pEvents);

		if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
			if (osample)
				IMFSample_Release(osample);
			return S_OK;
		}
		if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
			if (osample)
				IMFSample_Release(osample);
			decoder_negotiate_output(s);
			continue;
		}
		if (FAILED(hr)) {
			if (osample)
				IMFSample_Release(osample);
			return hr;
		}

		if (out.pSample) {
			output_frame(s, out.pSample);
			IMFSample_Release(out.pSample);
		}
	}
}

static void feed_access_unit(struct xrcam_src *s, const uint8_t *data, size_t size)
{
	if (!s->mft || size == 0)
		return;

	IMFSample *sample = NULL;
	IMFMediaBuffer *buf = NULL;
	if (FAILED(MFCreateSample(&sample)))
		return;
	if (FAILED(MFCreateMemoryBuffer((DWORD)size, &buf))) {
		IMFSample_Release(sample);
		return;
	}

	BYTE *dst = NULL;
	DWORD max = 0;
	if (SUCCEEDED(IMFMediaBuffer_Lock(buf, &dst, &max, NULL))) {
		memcpy(dst, data, size);
		IMFMediaBuffer_Unlock(buf);
		IMFMediaBuffer_SetCurrentLength(buf, (DWORD)size);
	}
	IMFSample_AddBuffer(sample, buf);
	IMFMediaBuffer_Release(buf);

	IMFSample_SetSampleTime(sample, s->pts);
	IMFSample_SetSampleDuration(sample, 333333); /* 1/30s in 100ns units */
	s->pts += 333333;

	HRESULT hr = IMFTransform_ProcessInput(s->mft, 0, sample, 0);
	if (hr == MF_E_NOTACCEPTING) {
		drain_outputs(s);
		hr = IMFTransform_ProcessInput(s->mft, 0, sample, 0);
	}
	IMFSample_Release(sample);

	if (SUCCEEDED(hr))
		drain_outputs(s);
}

/* ---------------------------------------------------------------- network */

static SOCKET connect_to(const char *host, int port)
{
	char portstr[16];
	snprintf(portstr, sizeof(portstr), "%d", port);

	struct addrinfo hints = {0};
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	struct addrinfo *res = NULL;
	if (getaddrinfo(host, portstr, &hints, &res) != 0)
		return INVALID_SOCKET;

	SOCKET sock = INVALID_SOCKET;
	for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
		sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (sock == INVALID_SOCKET)
			continue;
		if (connect(sock, ai->ai_addr, (int)ai->ai_addrlen) == 0)
			break;
		closesocket(sock);
		sock = INVALID_SOCKET;
	}
	freeaddrinfo(res);

	if (sock != INVALID_SOCKET) {
		DWORD nodelay = 1;
		setsockopt(sock, IPPROTO_TCP, TCP_NODELAY,
		           (const char *)&nodelay, sizeof(nodelay));
	}
	return sock;
}

/* Find the next AUD at/after `from`; SIZE_MAX if absent. */
static size_t find_aud(const uint8_t *buf, size_t len, size_t from)
{
	if (len < sizeof(AUD))
		return SIZE_MAX;
	for (size_t i = from; i + sizeof(AUD) <= len; i++) {
		if (buf[i] == 0 && memcmp(buf + i, AUD, sizeof(AUD)) == 0)
			return i;
	}
	return SIZE_MAX;
}

static DWORD WINAPI worker(LPVOID param)
{
	struct xrcam_src *s = param;

	CoInitializeEx(NULL, COINIT_MULTITHREADED);
	MFStartup(MF_VERSION, MFSTARTUP_LITE);

	uint8_t *buf = bmalloc(RECV_CHUNK * 4);
	size_t cap = RECV_CHUNK * 4;
	size_t len = 0;

	while (!InterlockedCompareExchange(&s->stop, 0, 0)) {
		char host[128];
		int port;
		EnterCriticalSection(&s->lock);
		memcpy(host, s->host, sizeof(host));
		port = s->port;
		LeaveCriticalSection(&s->lock);

		SOCKET sock = connect_to(host, port);
		if (sock == INVALID_SOCKET) {
			/* clear any stale picture while we cannot connect */
			obs_source_output_video(s->source, NULL);
			for (int i = 0; i < 10 && !s->stop; i++)
				Sleep(100);
			continue;
		}

		XR_LOG(LOG_INFO, "connected to %s:%d", host, port);
		s->sock = sock;
		len = 0;

		if (FAILED(decoder_create(s))) {
			closesocket(sock);
			s->sock = INVALID_SOCKET;
			break;
		}

		while (!InterlockedCompareExchange(&s->stop, 0, 0)) {
			if (len + RECV_CHUNK > cap) {
				cap *= 2;
				buf = brealloc(buf, cap);
			}

			int got = recv(sock, (char *)buf + len, RECV_CHUNK, 0);
			if (got <= 0)
				break;
			len += (size_t)got;

			/* Emit every complete AU: [AUD_n, AUD_n+1). */
			size_t start = find_aud(buf, len, 0);
			while (start != SIZE_MAX) {
				size_t next = find_aud(buf, len, start + sizeof(AUD));
				if (next == SIZE_MAX)
					break;
				feed_access_unit(s, buf + start, next - start);
				start = next;
			}
			if (start != SIZE_MAX && start > 0) {
				memmove(buf, buf + start, len - start);
				len -= start;
			} else if (start == SIZE_MAX && len > MAX_PENDING) {
				XR_LOG(LOG_WARNING, "no frame boundary in %zu bytes -- resetting", len);
				len = 0;
			}
		}

		s->sock = INVALID_SOCKET;
		closesocket(sock);
		if (s->mft)
			IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_COMMAND_FLUSH, 0);
		decoder_destroy(s);
		obs_source_output_video(s->source, NULL);
		XR_LOG(LOG_INFO, "disconnected");
	}

	bfree(buf);
	decoder_destroy(s);
	MFShutdown();
	CoUninitialize();
	return 0;
}

/* ------------------------------------------------------------- obs source */

static const char *xrcam_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "XRCam USB Camera";
}

static void xrcam_update(void *data, obs_data_t *settings)
{
	struct xrcam_src *s = data;

	EnterCriticalSection(&s->lock);
	snprintf(s->host, sizeof(s->host), "%s",
	         obs_data_get_string(settings, "host"));
	s->port = (int)obs_data_get_int(settings, "port");
	LeaveCriticalSection(&s->lock);

	/* Kick the worker off its current connection so new settings apply. */
	SOCKET sock = s->sock;
	if (sock != INVALID_SOCKET)
		closesocket(sock);
}

static void *xrcam_create(obs_data_t *settings, obs_source_t *source)
{
	struct xrcam_src *s = bzalloc(sizeof(*s));
	s->source = source;
	s->sock = INVALID_SOCKET;
	InitializeCriticalSection(&s->lock);

	WSADATA wsa;
	WSAStartup(MAKEWORD(2, 2), &wsa);

	/* Render the newest frame immediately; nothing here has timestamps
	 * worth waiting for. */
	obs_source_set_async_unbuffered(source, true);

	xrcam_update(s, settings);
	s->thread = CreateThread(NULL, 0, worker, s, 0, NULL);
	return s;
}

static void xrcam_destroy(void *data)
{
	struct xrcam_src *s = data;

	InterlockedExchange(&s->stop, 1);
	SOCKET sock = s->sock;
	if (sock != INVALID_SOCKET)
		closesocket(sock); /* unblock recv() */
	if (s->thread) {
		WaitForSingleObject(s->thread, 5000);
		CloseHandle(s->thread);
	}
	DeleteCriticalSection(&s->lock);
	bfree(s);
}

static void xrcam_get_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "host", "127.0.0.1");
	obs_data_set_default_int(settings, "port", 9000);
}

static obs_properties_t *xrcam_get_properties(void *data)
{
	UNUSED_PARAMETER(data);
	obs_properties_t *props = obs_properties_create();
	obs_properties_add_text(props, "host", "Host", OBS_TEXT_DEFAULT);
	obs_properties_add_int(props, "port", "Port", 1, 65535, 1);
	return props;
}

static struct obs_source_info xrcam_source_info = {
	.id = "xrcam_usb_source",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_DO_NOT_DUPLICATE,
	.get_name = xrcam_get_name,
	.create = xrcam_create,
	.destroy = xrcam_destroy,
	.update = xrcam_update,
	.get_defaults = xrcam_get_defaults,
	.get_properties = xrcam_get_properties,
};

bool obs_module_load(void)
{
	obs_register_source(&xrcam_source_info);
	XR_LOG(LOG_INFO, "loaded (built " __DATE__ " " __TIME__ ")");
	return true;
}
