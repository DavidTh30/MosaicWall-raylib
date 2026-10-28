# Writes the FactoryHMI PLC program (DB10 "HMI", FB1 "Station", FB2 "Line", OB1) as a TIA-style .scl source,
# read from the running Virtual PLC through its IPC pipe.
import json, sys
def tool(name, args):
    with open(chr(92)*2 + '.' + chr(92) + 'pipe' + chr(92) + 'VirtualPLC', 'r+b', buffering=0) as p:
        p.write(f'TOOL {name} {json.dumps(args)}\n'.encode())
        line = b''
        while not line.endswith(b'\n'):
            line += p.read(1 << 16)
    s = line.decode('utf-8').strip()
    assert s.startswith('OK '), s[:200]
    o = json.loads(s[3:]); assert not o['is_error'], o['text']
    return json.loads(o['text'])
proj = tool('get_project', {})
def iface(b, sections):
    out = []
    for sec, kw in sections:
        vs = [v for v in b['interface'] if v['section'] == sec]
        if not vs: continue
        out.append(f'   {kw}')
        for v in vs:
            c = f' // {v["comment"]}' if v['comment'] else ''
            out.append(f'      {v["name"]} : {v["type"]};{c}')
        out.append('   END_VAR')
    return out
def body(b):
    out = ['BEGIN']
    for n in b['networks']:
        out.append(f'   REGION {n["title"]}')
        if n['comment']: out.append(f'      // {n["comment"]}')
        for l in n['code'].replace('\r', '').rstrip().split('\n'):
            out.append(('      ' + l).rstrip())
        out.append('   END_REGION')
    return out
L = ['// FactoryHMI - Assembly Line A, PLC program for the Virtual PLC (S7-1200, CPU 1214C)',
     '// Import: Virtual PLC > Program > SCL source > Import .scl source ...; then Ports: S7 server on,',
     '// "Permit access with PUT/GET" on. DB10 "HMI" must stay non-optimized (S7 absolute access).',
     '// See SPEC_FactoryHMI.md section 9.', '']
db = next(d for d in proj['dbs'] if d['name'] == 'HMI')
L += ['DATA_BLOCK "HMI"', "{ S7_Optimized_Access := 'FALSE' }", 'VERSION : 0.1', 'NON_RETAIN', '   VAR']
for v in db['variables']:
    L.append(f'      {v["name"]} : {v["type"]} := {v["start"]}; // {v["comment"]}')
L += ['   END_VAR', 'BEGIN', 'END_DATA_BLOCK', '']
for name, num in (('Station', 1), ('Line', 2)):
    b = tool('get_block', {'block': name})
    L += [f'FUNCTION_BLOCK "{name}" // FB{num}', "{ S7_Optimized_Access := 'TRUE' }", 'VERSION : 0.1', f'// {b["comment"]}']
    L += iface(b, [('Input', 'VAR_INPUT'), ('Output', 'VAR_OUTPUT'), ('InOut', 'VAR_IN_OUT'), ('Static', 'VAR'), ('Temp', 'VAR_TEMP')])
    L += body(b) + ['END_FUNCTION_BLOCK', '']
L += ['DATA_BLOCK "Line_DB"', "{ S7_Optimized_Access := 'TRUE' }", 'VERSION : 0.1', 'NON_RETAIN', '"Line"', 'BEGIN', 'END_DATA_BLOCK', '']
b = tool('get_block', {'block': 'OB1'})
L += ['ORGANIZATION_BLOCK "Main" // OB1', "{ S7_Optimized_Access := 'TRUE' }", 'VERSION : 0.1']
L += iface(b, [('Input', 'VAR_INPUT'), ('Temp', 'VAR_TEMP')])
L += body(b) + ['END_ORGANIZATION_BLOCK', '']
open(sys.argv[1], 'w', encoding='utf-8', newline='\r\n').write('\n'.join(L))
print(len(L), 'lines')
