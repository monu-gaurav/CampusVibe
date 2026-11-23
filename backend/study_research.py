"""Source-backed extractive question answering for the free CampusVibe pilot."""
import os
import re
import threading
from functools import lru_cache
from pathlib import Path
from urllib.parse import quote
import httpx
from fastapi import HTTPException

busy = threading.BoundedSemaphore(1)
stop = set("what is are the a an of in on why how does do explain please me to for and with".split())

@lru_cache(maxsize=1)
def load_model():
    import onnxruntime as ort
    from tokenizers import Tokenizer
    root = Path(os.getenv("STUDY_MODEL_DIR","/opt/study-model"))
    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    options.enable_cpu_mem_arena = False
    tokenizer = Tokenizer.from_file(str(root/"tokenizer.json"))
    tokenizer.enable_truncation(max_length=384, strategy="only_second")
    return tokenizer, ort.InferenceSession(str(root/"model.onnx"),options,providers=["CPUExecutionProvider"])

def sources(question):
    terms = [t for t in re.findall(r"[\w+-]+",question) if t.lower() not in stop][:16]
    if not terms:
        return []
    with httpx.Client(timeout=12,headers={"User-Agent":"CampusVibeStudy/0.6 (https://github.com/monu-gaurav/CampusVibe)"}) as client:
        r=client.get("https://en.wikipedia.org/w/api.php",params={"action":"query","format":"json","generator":"search","gsrsearch":" ".join(terms),"gsrlimit":3,"prop":"extracts","explaintext":1,"exintro":1,"exchars":2200,"formatversion":2})
        r.raise_for_status()
        pages=sorted(r.json().get("query",{}).get("pages",[]),key=lambda page:page.get("index",100))
        return [(p["title"],p["extract"],"https://en.wikipedia.org/wiki/"+quote(p["title"].replace(" ","_"))) for p in pages if p.get("extract","").strip()]

def select_answer(question,pages):
    import numpy as np
    tokenizer,model=load_model()
    best=None
    for title,paragraph,url in pages:
        tokens=tokenizer.encode(question[:400],paragraph)
        inputs={"input_ids":tokens.ids,"attention_mask":tokens.attention_mask,"token_type_ids":tokens.type_ids}
        start,end=model.run(None,{i.name:np.array([inputs[i.name]],dtype=np.int64) for i in model.get_inputs()})
        null=float(start[0,0]+end[0,0])
        positions=[i for i,s in enumerate(tokens.sequence_ids) if s==1]
        for i in positions:
            jmax=min(i+44,positions[-1]+1)
            j=i+int(np.argmax(end[0,i:jmax]))
            score=float(start[0,i]+end[0,j])-null
            if score<=0 or (best and score<=best[0]):
                continue
            left,right=tokens.offsets[i][0],tokens.offsets[j][1]
            phrase=paragraph[left:right].strip()
            if phrase:
                sentence_start=max(paragraph.rfind(". ",0,left)+2 if ". " in paragraph[:left] else 0,paragraph.rfind("\n",0,left)+1)
                after=re.search(r"[.!?](?:\s|$)|\n",paragraph[right:])
                sentence_end=right+after.end() if after else len(paragraph)
                context=paragraph[sentence_start:sentence_end].strip()
                best=(score,phrase,context if len(context)<=650 else phrase,title,url)
    return best

def research(question):
    if not busy.acquire(blocking=False):
        raise HTTPException(429,"The study assistant is helping another student. Try again shortly.")
    try:
        pages=sources(question)
        answer=select_answer(question,pages) if pages else None
        if not answer:
            links="\n".join(f"{p[0]} — {p[2]}" for p in pages[:2])
            return {"answer":"I could not establish an answer from the sources. Try a specific concept question."+("\n\nRelated reading\n"+links if links else "")}
        _,phrase,context,title,url=answer
        return {"answer":f"{phrase}\n\n{context}\n\nSource: {title}\n{url}" if context!=phrase else f"{phrase}\n\nSource: {title}\n{url}"}
    except (httpx.HTTPError,ValueError,OSError) as exc:
        raise HTTPException(503,"Study search is temporarily unavailable. Please try again.") from exc
    finally:
        busy.release()
