from pathlib import Path
from urllib.request import urlopen
import hashlib
root=Path('/opt/study-model')
root.mkdir(exist_ok=True)
base='https://huggingface.co/onnx-community/mobilebert-uncased-squad-v2-ONNX/resolve/a8d7291835b8b6481505577f2aa98db0d3a4f601/'
for remote,local,digest in [('onnx/model_int8.onnx','model.onnx','a59cc2b740b9ad10299e3280bc9e7ef325a3fa98b9e39f1d9a8ebfb9d2384083'),('tokenizer.json','tokenizer.json','688882a79f44442ddc1f60d70334a7ff5df0fb47')]:
    data=urlopen(base+remote,timeout=100).read()
    actual=hashlib.sha256(data).hexdigest() if local.endswith('onnx') else hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    if actual!=digest:raise ValueError('Downloaded model failed integrity check')
    (root/local).write_bytes(data)
