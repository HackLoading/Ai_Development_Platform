import threading
import time
import requests

url_chat = "http://localhost:8000/v1/chat/completions"
url_metrics = "http://localhost:8000/metrics"

result = {}

def poll_metrics():
    max_running = 0
    max_waiting = 0
    for _ in range(50):
        try:
            r = requests.get(url_metrics)
            if r.status_code == 200:
                for line in r.text.split('\n'):
                    if line.startswith('vllm:num_requests_running') and '{' in line:
                        val = float(line.split()[-1])
                        if val > max_running: max_running = val
                    if line.startswith('vllm:num_requests_waiting') and '{' in line:
                        val = float(line.split()[-1])
                        if val > max_waiting: max_waiting = val
        except:
            pass
        time.sleep(0.1)
    result['running'] = max_running
    result['waiting'] = max_waiting

def send_chat():
    try:
        requests.post(url_chat, json={
            "model": "tinyllama",
            "messages": [{"role": "user", "content": "Write a massive essay on the history of civilization."}],
            "max_tokens": 1000
        }, headers={"X-API-Key": "demo-api-key-12345"})
    except:
        pass

# Start 5 concurrent long chats
threads = []
for _ in range(5):
    t = threading.Thread(target=send_chat)
    t.start()
    threads.append(t)

# Rapidly poll metrics
t_poll = threading.Thread(target=poll_metrics)
t_poll.start()

t_poll.join()
print(f"MAX RUNNING OBSERVED: {result.get('running')}")
print(f"MAX WAITING OBSERVED: {result.get('waiting')}")
