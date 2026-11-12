from pathlib import Path
import json, math, heapq, collections, html, random
D=Path(__file__).parent
P=2.54; W=30; H=40
pins=[]; parts=[]
def part(ref,name,points,box=None,note=''):
    pp=[]
    for i,(x,y,label,net) in enumerate(points,1):
        p=dict(ref=ref,pin=str(i),x=x,y=y,label=label,net=net,id=f'{ref}.{i}',hole=f'{x:02d}/{y:02d}')
        pins.append(p);pp.append(p)
    parts.append(dict(ref=ref,name=name,pins=pp,box=box,note=note))
part('U1','ESP32-C3 SuperMini',[(5,2+i,l,n) for i,(l,n) in enumerate([('5','SCL'),('6','MOVE'),('7','SCROLL'),('8',''),('9',''),('10',''),('20',''),('21','')])]+[(11,2+i,l,n) for i,(l,n) in enumerate([('5V','V5'),('GND','GND'),('3V3','V3V3'),('4','SDA'),('3',''),('2',''),('1','RIGHT'),('0','LEFT')])], [4.4,0.7,7.2,9.1], 'Two 1×8 female sockets; row spacing 15.24 mm. USB faces row 1. Verify your board labels before insertion.')
part('U2','MPU-6050 / GY-521',[(22,3+i,l,n) for i,(l,n) in enumerate([('VCC','V3V3'),('GND','GND'),('SCL','SCL'),('SDA','SDA'),('XDA',''),('XCL',''),('AD0','GND'),('INT','')])],[21.3,2.2,7.7,9], '1×8 female socket. Body outline is indicative; fit your actual module. AD0 tied low. XDA, XCL and INT unused.')
for ref,name,x,y,net in [('J1','Left click',5,19,'LEFT'),('J2','Right click',19,19,'RIGHT'),('J3','Hold to move',5,25,'MOVE'),('J4','Hold to scroll',19,25,'SCROLL')]:
    part(ref,name,[(x,y,'SIG',net),(x+1,y,'GND','GND')],[x-1,y-2,4,4], '2-pin 2.54 mm switch connection, NOT a 4-leg tactile-switch footprint. Wire opposite electrical contacts of your existing switch to these pads; mount switch to suit its measured lead spacing.')
part('J5','Charger interface',[(4+i,32,l,n) for i,(l,n) in enumerate([('B+','BAT_PLUS'),('B−','BAT_MINUS'),('OUT+','PROTECTED_PLUS'),('OUT−','GND')])],[2.5,30,7,8], 'Four separate wires to the printed TP4056 module labels; this is not its physical module footprint. Keep B− separate from OUT−.')
part('J6','Battery connector',[(4,37,'+','BAT_PLUS'),(5,37,'−','BAT_MINUS')],None,'2.54 mm header/wire pads, not a JST-PH footprint. Check polarity. Cell stays off the carrier.')
part('J7','Power switch',[(13,32,'IN','PROTECTED_PLUS'),(14,32,'OUT','SWITCHED_BAT')],None,'External SPST switch via two wires; opens the positive battery feed. OFF for charging and for ESP32 USB.')
part('J8','5 V regulator interface',[(20+i,32,l,n) for i,(l,n) in enumerate([('IN+','SWITCHED_BAT'),('GND','GND'),('OUT+','BOOST_5V')])],[18.5,30,7.8,8], 'External regulated 5 V boost module, input covers protected 1-cell Li-ion range, >=500 mA output over that range. Join both regulator ground terminals to J8.2 if separate. Set output before connecting U1.')
part('JP1','Battery isolation link',[(16,3,'BOOST','BOOST_5V'),(17,3,'C3','V5')],None,'2-pin shunt. REMOVE before plugging USB into the ESP32. No automatic source selection is implemented.')
part('C1','100 nF ceramic',[(17,10,'+','V3V3'),(18,10,'−','GND')],None,'2.54 mm pitch, non-polarized. Across sensor supply.')
part('C2','100 µF / 10 V',[(16,7,'+','V5'),(17,7,'−','GND')],None,'2.54 mm lead pitch electrolytic, diameter <=6.3 mm. Observe polarity.')
nets=list(dict.fromkeys(p['net'] for p in pins if p['net']))
colors={'GND':'#a8b9ce','V3V3':'#ffbc62','V5':'#ff6485','BOOST_5V':'#ff6485','SDA':'#53e7c1','SCL':'#55baff','LEFT':'#c19aff','RIGHT':'#f48bd1','MOVE':'#8ad85d','SCROLL':'#f7df68','BAT_PLUS':'#f76b6b','BAT_MINUS':'#9ea6b5','PROTECTED_PLUS':'#e99255','SWITCHED_BAT':'#e7af60'}
occ=[{},{}]
for p in pins:
    for o in occ:o[p['x'],p['y']]=p['net'] or p['id']
def blocked(x,y):return 6<=x<=10 and 9<=y<=15
# Routed on 2.54 mm grid. No vias: top-layer escape uses through-hole endpoints.
def search(a,b,net,layer):
    start=(a['x'],a['y']);end=(b['x'],b['y']);q=[(0,0,start)];cost={start:0};prev={}
    while q:
        _,c,u=heapq.heappop(q)
        if u==end:
            path=[u]
            while u!=start:u=prev[u];path.append(u)
            return path[::-1]
        if c!=cost[u]:continue
        for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]:
            v=u[0]+dx,u[1]+dy
            if not (1<=v[0]<W and 1<=v[1]<H) or blocked(*v):continue
            if occ[layer].get(v,net)!=net:continue
            # Prevent crossing an unrelated through-hole pad on either layer.
            nc=c+1
            if nc<cost.get(v,1e9):
                cost[v]=nc;prev[v]=u;heapq.heappush(q,(nc+abs(v[0]-end[0])+abs(v[1]-end[1]),nc,v))
    return None
for attempt in range(300):
    occ=[{},{}]
    for p in pins:
        for o in occ:o[p['x'],p['y']]=p['net'] or p['id']
    order=nets[:];random.Random(attempt).shuffle(order)
    try:
        routes=[]
        # Low-fanout signal nets first; ground last.
        for net in order:
            remaining=[p for p in pins if p['net']==net];tree=[remaining.pop(0)]
            while remaining:
                choices=sorted((abs(a['x']-b['x'])+abs(a['y']-b['y']),a['id'],b['id'],a,b) for a in tree for b in remaining)
                found=None
                for layer in (0,1):
                    for _,_,_,a,b in choices:
                        path=search(a,b,net,layer)
                        if path:found=(a,b,path,layer);break
                    if found:break
                if not found:raise RuntimeError('Cannot route '+net)
                a,b,path,layer=found
                for v in path:occ[layer][v]=net
                routes.append(dict(id=f'W{len(routes)+1:02}',net=net,a=a['id'],b=b['id'],path=path,layer='B.Cu' if layer==0 else 'F.Cu',length=round((len(path)-1)*P,1)))
                tree.append(b);remaining.remove(b)
        break
    except RuntimeError:
        if attempt==299:raise
print('Routing order seed',attempt)
# KiCad board: real plated holes, copper segments and board outline; no decorative fake traces.
def mm(v):return f'{v*P:.4f}'
def esc(s):return json.dumps(s,ensure_ascii=False)
k=['(kicad_pcb (version 20221018) (generator pcbnew) (general (thickness 1.6)) (paper "A4")', '(layers (0 "F.Cu" signal) (31 "B.Cu" signal) (36 "B.SilkS" user "b.silkscreen") (37 "F.SilkS" user "f.silkscreen") (38 "B.Mask" user) (39 "F.Mask" user) (44 "Edge.Cuts" user) (46 "B.CrtYd" user) (47 "F.CrtYd" user) (48 "B.Fab" user) (49 "F.Fab" user))', '(setup (pad_to_mask_clearance 0))', '(net 0 "")']
for i,n in enumerate(nets,1):k.append(f'(net {i} "{n}")')
for part in parts:
    x0=part['pins'][0]['x'];y0=part['pins'][0]['y']
    k.append(f'(footprint "GyroCarrier:{part["ref"]}" (layer "F.Cu") (at {mm(x0)} {mm(y0)}) (attr through_hole)')
    k.append(f'(fp_text reference "{part["ref"]}" (at 0 -2.2) (layer "F.SilkS") (effects (font (size 1 1) (thickness 0.15))))')
    k.append(f'(fp_text value {esc(part["name"])} (at 0 2.5) (layer "F.Fab") (effects (font (size 1 1) (thickness 0.15))))')
    for p in part['pins']:
        nt=f'(net {nets.index(p["net"])+1} "{p["net"]}")' if p['net'] else ''
        shape='rect' if p['pin']=='1' else 'circle'
        k.append(f'(pad "{p["pin"]}" thru_hole {shape} (at {mm(p["x"]-x0)} {mm(p["y"]-y0)}) (size 1.8 1.8) (drill 1.0) (layers "*.Cu" "*.Mask") {nt})')
    k.append(')')
for r in routes:
    for a,b in zip(r['path'],r['path'][1:]):
        k.append(f'(segment (start {mm(a[0])} {mm(a[1])}) (end {mm(b[0])} {mm(b[1])}) (width 0.6) (layer "{r["layer"]}") (net {nets.index(r["net"])+1}))')
for a,b in [((0,0),(W,0)),((W,0),(W,H)),((W,H),(0,H)),((0,H),(0,0))]:
    k.append(f'(gr_line (start {mm(a[0])} {mm(a[1])}) (end {mm(b[0])} {mm(b[1])}) (stroke (width 0.05) (type default)) (layer "Edge.Cuts"))')
k.append('(gr_text "GYRO SENSOR / REV A / VERIFY MODULES" (at 38.1 73.66) (layer "F.SilkS") (effects (font (size 1 1) (thickness 0.15))))')
k.append(')');pcb='\n'.join(k)
(D/'gyro-carrier.kicad_pcb').write_text(pcb)
# Connectivity verification independent of tree-building state.
for net in nets:
    ps=[p['id'] for p in pins if p['net']==net];adj=collections.defaultdict(set)
    for r in routes:
        if r['net']==net:adj[r['a']].add(r['b']);adj[r['b']].add(r['a'])
    seen=set();todo=[ps[0]]
    while todo:
        u=todo.pop()
        if u not in seen:seen.add(u);todo+=list(adj[u]-seen)
    assert set(ps)<=seen,net
assert len({(p['x'],p['y']) for p in pins})==len(pins)
# Geometric clearance at 2.54 mm orthogonal routing: vertices and segments cannot overlap different nets.
for layer in ['B.Cu','F.Cu']:
    edges={};vertices={}
    for r in routes:
        if r['layer']!=layer:continue
        for a in r['path']:
            assert vertices.get(tuple(a),r['net'])==r['net'];vertices[tuple(a)]=r['net']
        for a,b in zip(r['path'],r['path'][1:]):
            e=tuple(sorted((tuple(a),tuple(b))));assert edges.get(e,r['net'])==r['net'];edges[e]=r['net']
report={'pins':len(pins),'nets':len(nets),'routes':len(routes),'top_routes':sum(r['layer']=='F.Cu' for r in routes),'checks':['All assigned pads connected','No duplicate pad coordinates','No cross-net grid vertex or segment overlap','No route in marked antenna keepout'],'limitation':'Custom grid checks only. KiCad parser/DRC and physical module fit not validated; not released for fabrication.'}
data=dict(pins=pins,parts=parts,routes=routes,colors=colors,nets=nets,width=W,height=H,pitch=P,report=report)
(D/'design.json').write_text(json.dumps(data,indent=2))
(D/'checks.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report))
# Browser package is self-contained, including editable board and data downloads.
template=(D/'viewer-template.html').read_text()
(D/'gyro-pcb.html').write_text(template.replace('__DATA__',json.dumps(data)).replace('__PCB__',json.dumps(pcb)))
