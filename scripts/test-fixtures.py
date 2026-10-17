"""Generate small, synthetic PDFs. No user documents are used in tests."""
from pathlib import Path
root=Path(__file__).resolve().parent.parent/'tests'/'fixtures'
root.mkdir(exist_ok=True)
def pdf(name,title,count,landscape=False,mixed=False):
    width,height=(842,595) if landscape else (595,842)
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',None,b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    kids=[]
    for index in range(count):
        width,height=(842,595) if landscape or (mixed and index%2) else (595,842)
        page=len(objects)+1;stream=page+1;kids.append(f'{page} 0 R')
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] /Resources << /Font << /F1 3 0 R >> >> /Contents {stream} 0 R >>'.encode())
        content=f'0.09 0.30 0.39 rg 50 {height-110} {width-100} 60 re f BT /F1 23 Tf 1 1 1 rg 68 {height-88} Td ({title}) Tj ET\nBT /F1 12 Tf 0.15 0.2 0.25 rg 50 {height-160} Td (Page {index+1} of {count}) Tj 0 -40 Td (Compare this page with the PDF beside it.) Tj 0 -30 Td (Searchable text: momentum and energy.) Tj ET\n'.encode()
        objects.append(f'<< /Length {len(content)} >>\nstream\n'.encode()+content+b'endstream')
    objects[1]=f'<< /Type /Pages /Kids [{" ".join(kids)}] /Count {count} >>'.encode()
    data=bytearray(b'%PDF-1.7\n');offsets=[0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(data));data+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
    xref=len(data);data+=f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode()
    for offset in offsets[1:]:data+=f'{offset:010d} 00000 n \n'.encode()
    data+=f'trailer << /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF'.encode()
    (root/name).write_bytes(data)
pdf('questions.pdf','Physics / Question paper',5)
pdf('answers.pdf','Physics / Worked answers',3)
pdf('reference.pdf','Reference sheet',2,True)
(root/'invalid.pdf').write_text('This is not a PDF.')
(root/'notes.txt').write_text('Not a PDF.')

pdf('long.pdf','Long document',80,mixed=True)
