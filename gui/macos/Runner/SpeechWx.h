// The C interface of rust/speech-wx (WeChat IME's offline speech model; wx offline ASR design §5.1), seen only
// when the app is built with RAPP_SPEECH=wx (gui/Speech.xcconfig passes -DRAPP_SPEECH_WX to the bridging header).
// Strings returned are UTF-8 and freed with wx_string_free; a stream is used from one thread at a time.
#ifdef RAPP_SPEECH_WX
#include <stddef.h>
#include <stdint.h>

typedef struct WxModel WxModel;
typedef struct WxStream WxStream;

/// Loads the model directory (the speech pack's .xnet file and dict.decoder.utf8.txt). NULL on failure, with
/// the reason in *err when err is not NULL.
WxModel *wx_load(const char *dir, char **err);
void wx_model_free(WxModel *model);
/// Starts a recording; it keeps its own reference to the model.
WxStream *wx_stream_new(const WxModel *model);
/// 16 kHz mono 16-bit samples.
void wx_push(WxStream *stream, const int16_t *pcm, size_t n);
/// A new partial text, or NULL when none is due yet or it has not changed.
char *wx_partial(WxStream *stream);
/// Ends and frees the recording; the final text (NULL only if decoding failed).
char *wx_finish(WxStream *stream);
/// Frees a recording without decoding it.
void wx_stream_free(WxStream *stream);
void wx_string_free(char *s);
#endif
