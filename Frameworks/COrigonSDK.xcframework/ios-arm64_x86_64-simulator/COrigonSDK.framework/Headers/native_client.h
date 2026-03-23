/**
 * native_client.h — C header for the native-client SDK FFI layer.
 *
 * All functions are prefixed with `origon_`. Opaque handles are forward-
 * declared as incomplete struct types. Every heap allocation returned by this
 * library has a paired free function.
 *
 * Return convention for fallible operations:
 *   0  = success
 *  -1  = error
 *
 * String return values are heap-allocated and must be freed with
 * `origon_string_free`.
 */

#ifndef NATIVE_CLIENT_H
#define NATIVE_CLIENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Opaque handles ── */

typedef struct OrigonClient OrigonClient;
typedef struct OrigonProgressReceiver OrigonProgressReceiver;

/* ── Enums ── */

typedef enum {
    ORIGON_CHANNEL_CHAT  = 0,
    ORIGON_CHANNEL_VOICE = 1,
} OrigonChannel;

typedef enum {
    ORIGON_CONTROL_AGENT = 0,
    ORIGON_CONTROL_HUMAN = 1,
} OrigonControl;

typedef enum {
    ORIGON_MESSAGE_ROLE_ASSISTANT  = 0,
    ORIGON_MESSAGE_ROLE_USER       = 1,
    ORIGON_MESSAGE_ROLE_SUPERVISOR = 2,
    ORIGON_MESSAGE_ROLE_SYSTEM     = 3,
    ORIGON_MESSAGE_ROLE_TOOL       = 4,
} OrigonMessageRole;

typedef enum {
    ORIGON_EVENT_NONE            = 0,
    ORIGON_EVENT_MESSAGE_ADDED   = 1,
    ORIGON_EVENT_MESSAGE_UPDATED = 2,
    ORIGON_EVENT_SESSION_UPDATED = 3,
    ORIGON_EVENT_CONTROL_UPDATED = 4,
    ORIGON_EVENT_TOOL_CALLS      = 5,
    ORIGON_EVENT_TYPING          = 6,
    ORIGON_EVENT_CALL_STATUS     = 7,
    ORIGON_EVENT_CALL_ERROR      = 8,
} OrigonEventType;

/* ── Structs ── */

typedef struct {
    const char *endpoint;
    const char *token;
    const char *external_id;
} OrigonConfig;

typedef struct {
    OrigonChannel channel;
    const char *session_id;
    int fetch_session;
} OrigonStartSessionOptions;

typedef struct {
    char *media_id;
    char *url;
} OrigonAttachmentInfo;

typedef struct {
    char *tool_call_id;
    char *tool_name;
    uint8_t *arguments;
    uint32_t arguments_len;
} OrigonToolCall;

typedef struct {
    char *key;
    char *value;
} OrigonKeyValue;

typedef struct {
    OrigonMessageRole role;
    char *text;
    char *html;
    char *timestamp;
    int loading;
    int done;
    char *error_text;
    OrigonAttachmentInfo *attachments;
    uint32_t attachments_len;
    OrigonToolCall *tool_calls;
    uint32_t tool_calls_len;
    char *tool_call_id;
    char *tool_name;
    OrigonKeyValue *meta;
    uint32_t meta_len;
} OrigonMessage;

typedef struct {
    char *session_id;
    OrigonMessage *messages;
    uint32_t messages_len;
    OrigonControl control;
    OrigonKeyValue *config_data;
    uint32_t config_data_len;
    int active;
} OrigonSessionInfo;

typedef struct {
    char *session_id;
    OrigonChannel channel;
    char *created_at;
    char *updated_at;
    OrigonMessage last_message;
} OrigonSessionSummary;

typedef struct {
    OrigonSessionSummary *items;
    uint32_t len;
} OrigonSessionList;

typedef struct {
    OrigonControl control;
    OrigonMessage *messages;
    uint32_t messages_len;
} OrigonGetSessionResult;

typedef struct {
    double percent;
    uint64_t loaded;
    uint64_t total;
} OrigonUploadProgress;

typedef struct {
    OrigonAttachmentInfo attachment;
    OrigonProgressReceiver *progress_handle;
} OrigonUploadResult;

typedef struct {
    const uint8_t *data;
    uint32_t len;
} OrigonBuffer;

typedef struct {
    const char *text;
    const char *html;
    const uint8_t *context;
    uint32_t context_len;
    const OrigonAttachmentInfo *attachments;
    uint32_t attachments_len;
    const char *type;
    const OrigonBuffer *results;
    uint32_t results_len;
    const OrigonKeyValue *meta;
    uint32_t meta_len;
} OrigonSendMessagePayload;

typedef struct {
    OrigonEventType event_type;
    OrigonMessage message;
    uint32_t index;
    char *session_id;
    OrigonControl control;
    OrigonToolCall *tool_calls;
    uint32_t tool_calls_len;
    int typing;
    char *call_status;
    char *call_error;
    int call_error_present;
} OrigonEvent;

/* ── Lifecycle ── */

OrigonClient *origon_client_create(const OrigonConfig *config);
void origon_client_destroy(OrigonClient *client);

/* ── Events ── */

OrigonEvent origon_client_poll_event(OrigonClient *client);
void origon_event_free(OrigonEvent *event);

/* ── Sessions ── */

int origon_client_start_session(
    OrigonClient *client,
    const OrigonStartSessionOptions *options,
    OrigonSessionInfo *out);

int origon_client_get_sessions(
    OrigonClient *client,
    OrigonSessionList *out);

int origon_client_get_session(
    OrigonClient *client,
    const char *session_id,
    OrigonGetSessionResult *out);

int origon_client_end_session(OrigonClient *client);

/* ── Messaging ── */

int origon_client_send_message(
    OrigonClient *client,
    const OrigonSendMessagePayload *payload,
    char **out_session_id);

/* ── Attachments ── */

int origon_client_upload_attachment(
    OrigonClient *client,
    const uint8_t *data,
    uint32_t data_len,
    const char *filename,
    OrigonUploadResult *out);

int origon_progress_poll(
    OrigonProgressReceiver *handle,
    OrigonUploadProgress *out);

void origon_progress_free(OrigonProgressReceiver *handle);

int origon_client_delete_attachment(
    OrigonClient *client,
    const char *media_id);

char *origon_client_get_attachment_url(
    OrigonClient *client,
    const char *media_id);

/* ── Voice ── */

int origon_client_toggle_mute(
    OrigonClient *client,
    int *out_muted);

/* ── Free helpers ── */

void origon_string_free(char *s);
void origon_message_free(OrigonMessage *msg);
void origon_attachment_info_free(OrigonAttachmentInfo *att);
void origon_tool_call_free(OrigonToolCall *tc);
void origon_session_info_free(OrigonSessionInfo *info);
void origon_session_list_free(OrigonSessionList *list);
void origon_get_session_result_free(OrigonGetSessionResult *result);
void origon_upload_result_free(OrigonUploadResult *result);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_CLIENT_H */
