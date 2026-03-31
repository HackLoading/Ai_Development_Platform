# AI Inference Platform Demo (vLLM + Gateway + Monitoring)

This repo runs an end-to-end inference stack on your laptop:

- **Host vLLM (GPU in Docker)** (TinyLlama)
- **FastAPI Gateway on Minikube** (OpenAI-compatible API + SSE streaming + API key auth)
- **Prometheus + Grafana** (live vLLM metrics)
- **ArgoCD UI** (GitOps dashboard)
- **Local TinyLlama Chat UI** at `http://localhost:3001`

## One-command start

From **Windows PowerShell** (repo folder can be anywhere):

```powershell
& "C:\Users\Atharva Badgujar\Desktop\projects\New folder\Inference Prototype\ai-platform-demo\ai-platform-demo\scripts\Start-Demo.ps1"
```

It will:

1. Start host vLLM on port `8000`
2. Deploy gateway into Minikube
3. Install/upgrade monitoring (Grafana + Prometheus)
4. Create an in-cluster metrics proxy so Grafana metrics work reliably
5. Start port-forwards:
   - Grafana: `http://localhost:3000` (admin / admin123)
   - Prometheus: `http://localhost:9090`
   - Gateway API: `http://localhost:8080`
   - TinyLlama UI: `http://localhost:3001`
6. Keep running (so tunnels stay alive)

## One-command stop

```powershell
& "C:\Users\Atharva Badgujar\Desktop\projects\New folder\Inference Prototype\ai-platform-demo\ai-platform-demo\scripts\Stop-Demo.ps1"
```

## Verify everything quickly

After start completes, open:

- Grafana: `http://localhost:3000`
- TinyLlama UI: `http://localhost:3001`

Also run the existing test script (optional):

```bash
python test/test_api.py --base-url http://localhost:8080 --api-key demo-api-key-12345 --model tinyllama
```

## Notes

- If you haven’t built the `ai-gateway:latest` Docker image yet, gateway deployment may fail.
- This demo is designed for “uninterrupted” use: the start script keeps port-forwards alive.

