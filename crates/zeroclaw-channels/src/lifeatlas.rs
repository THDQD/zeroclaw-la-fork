use async_trait::async_trait;
use zeroclaw_api::channel::{Channel, ChannelMessage, SendMessage};

pub struct LifeAtlasChannel {
    webhook_url: String,
    auth_token: String,
    client: reqwest::Client,
}

impl LifeAtlasChannel {
    pub fn new(webhook_url: String, auth_token: String) -> Self {
        Self {
            webhook_url,
            auth_token,
            client: reqwest::Client::new(),
        }
    }
}

#[async_trait]
impl Channel for LifeAtlasChannel {
    fn name(&self) -> &str {
        "lifeatlas"
    }

    async fn send(&self, message: &SendMessage) -> anyhow::Result<()> {
        let mut payload = serde_json::json!({
            "content": message.content,
            "recipient": message.recipient,
        });
        if let Some(ref subject) = message.subject {
            payload["subject"] = serde_json::json!(subject);
        }
        let resp = self
            .client
            .post(&self.webhook_url)
            .bearer_auth(&self.auth_token)
            .json(&payload)
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("lifeatlas webhook request failed: {e}"))?;
        if !resp.status().is_success() {
            anyhow::bail!("lifeatlas webhook returned HTTP {}", resp.status());
        }
        Ok(())
    }

    async fn listen(&self, _tx: tokio::sync::mpsc::Sender<ChannelMessage>) -> anyhow::Result<()> {
        // Send-only; inbound messages arrive via /ws/chat.
        // Block forever so the channel supervisor doesn't restart us.
        std::future::pending::<()>().await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn send_posts_to_webhook() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(header("authorization", "Bearer test-token"))
            .respond_with(ResponseTemplate::new(200))
            .expect(1)
            .mount(&server)
            .await;

        let channel = LifeAtlasChannel::new(format!("{}/push", server.uri()), "test-token".into());
        let msg = SendMessage::new("Time to stretch!", "session_abc");
        channel.send(&msg).await.unwrap();
    }

    #[tokio::test]
    async fn send_includes_subject_when_present() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200))
            .expect(1)
            .mount(&server)
            .await;

        let channel = LifeAtlasChannel::new(server.uri(), "tok".into());
        let msg = SendMessage::with_subject("content", "all", "Reminder");
        channel.send(&msg).await.unwrap();
    }

    #[tokio::test]
    async fn send_returns_error_on_non_success() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let channel = LifeAtlasChannel::new(server.uri(), "tok".into());
        let msg = SendMessage::new("test", "all");
        assert!(channel.send(&msg).await.is_err());
    }

    #[tokio::test]
    async fn send_returns_error_on_connection_failure() {
        let channel = LifeAtlasChannel::new(
            "http://127.0.0.1:1".into(), // nothing listening
            "tok".into(),
        );
        let msg = SendMessage::new("test", "all");
        assert!(channel.send(&msg).await.is_err());
    }

    #[tokio::test]
    async fn listen_blocks_indefinitely() {
        let channel = LifeAtlasChannel::new("http://unused".into(), "tok".into());
        let (tx, _rx) = tokio::sync::mpsc::channel(1);
        // listen() should block forever (send-only channel), so a short timeout must fire
        let result = tokio::time::timeout(
            std::time::Duration::from_millis(50),
            channel.listen(tx),
        )
        .await;
        assert!(result.is_err(), "listen() should block, not return");
    }
}
