from pathlib import Path
import xml.etree.ElementTree as ET
import html
import math
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent
W, H = 1920, 1200
C = dict(ink='#14263D', muted='#52667C', blue='#2563EB', teal='#008778', purple='#7852C5', amber='#AD6200', line='#CAD5E2')
FONT = Path('C:/Windows/Fonts')

class Page:
    def __init__(self, name, title, subtitle):
        self.name, self.nodes, self.edges = name, [], []
        self.text('title', title, 60, 35, 1800, 55, 32, C['ink'], True)
        self.text('subtitle', subtitle, 60, 95, 1800, 38, 18, C['muted'])
    def box(self, id, title, body, x,y,w,h, color='blue', fill=None, size=19, group=False):
        colors = {'blue':'#EEF4FF','teal':'#EAF8F4','purple':'#F3EEFC','amber':'#FFF5E6','muted':'#F3F6FA'}
        self.nodes.append(dict(id=id,title=title,body=body,x=x,y=y,w=w,h=h,size=size,color=C.get(color,color),fill=fill or colors.get(color,'#FFFFFF'),group=group,text=False))
        return id
    def text(self,id,title,x,y,w,h,size=18,color=None,bold=False):
        self.nodes.append(dict(id=id,title=title,body='',x=x,y=y,w=w,h=h,size=size,color=color or C['muted'],fill='none',group=False,text=True,bold=bold))
    def edge(self, source,target, pts, label='', color='blue', dashed=False, at=None):
        self.edges.append(dict(source=source,target=target,pts=pts,label=label,color=C.get(color,color),dashed=dashed,at=at))
    def footer(self,n):
        self.text('foot',f'QUBERSHIP CLUSTER MANAGER  /  LOCAL ARCHITECTURE                        Source snapshot: 2026-10-28                        {n:02d} / 05',60,1140,1800,28,16)

def font(size,bold=False):
    return ImageFont.truetype(str(FONT/('segoeuib.ttf' if bold else 'segoeui.ttf')),size)

def export(page,index,mxfile):
    diagram=ET.SubElement(mxfile,'diagram',{'id':f'page-{index}','name':page.name})
    model=ET.SubElement(diagram,'mxGraphModel',{'dx':'1920','dy':'1200','grid':'1','gridSize':'10','guides':'1','tooltips':'1','connect':'1','arrows':'1','fold':'1','page':'1','pageScale':'1','pageWidth':str(W),'pageHeight':str(H),'math':'0','shadow':'0','background':'#FFFFFF'})
    root=ET.SubElement(model,'root'); ET.SubElement(root,'mxCell',{'id':'0'}); ET.SubElement(root,'mxCell',{'id':'1','parent':'0'})
    im=Image.new('RGB',(W,H),'white'); d=ImageDraw.Draw(im)
    # Background groups first; connectors then foreground nodes for clean layering.
    def render_node(n):
        x,y,w,h=n['x'],n['y'],n['w'],n['h']
        if not n['text']:
            d.rounded_rectangle((x,y,x+w,y+h),radius=12,fill=n['fill'],outline=n['color'],width=2 if not n['group'] else 1)
        tx=x if n['text'] else x+18
        ty=y+2 if n['text'] else y+13
        for line in n['title'].split('\n'):
            d.text((tx,ty),line,font=font(n['size'],n.get('bold',True)),fill=n['color']); ty+=n['size']+7
        if n['body']:
            ty+=3
            for line in n['body'].split('\n'):
                d.text((tx,ty),line,font=font(max(n['size']-1,15)),fill=C['muted']); ty+=n['size']+7
    for n in page.nodes:
        if n['group']: render_node(n)
    for i,e in enumerate(page.edges):
        pts=e['pts']; color=e['color']
        for a,b in zip(pts,pts[1:]):
            if e['dashed']:
                length=math.dist(a,b)
                for pos in range(0,int(length),13):
                    end=min(pos+7,length)
                    d.line((a[0]+(b[0]-a[0])*pos/length,a[1]+(b[1]-a[1])*pos/length,a[0]+(b[0]-a[0])*end/length,a[1]+(b[1]-a[1])*end/length),fill=color,width=2)
            else:d.line((a,b),fill=color,width=2)
        a,b=pts[-2:]; ang=math.atan2(b[1]-a[1],b[0]-a[0]); d.polygon([b,(b[0]-10*math.cos(ang-.42),b[1]-10*math.sin(ang-.42)),(b[0]-10*math.cos(ang+.42),b[1]-10*math.sin(ang+.42))],fill=color)
        if e['label']:
            cx,cy=e['at'] or ((pts[0][0]+pts[-1][0])/2,(pts[0][1]+pts[-1][1])/2)
            bb=d.textbbox((0,0),e['label'],font=font(15)); tw=bb[2]-bb[0]
            d.rectangle((cx-tw/2-5,cy-3,cx+tw/2+5,cy+21),fill='white'); d.text((cx-tw/2,cy-2),e['label'],font=font(15),fill=color)
        style=f'edgeStyle=none;rounded=0;html=1;endArrow=block;endFill=1;strokeColor={color};strokeWidth=2;fontFamily=Segoe UI;fontSize=15;fontColor={color};labelBackgroundColor=#FFFFFF;'
        if e['dashed']:style+='dashed=1;'
        by_id={n['id']:n for n in page.nodes}
        src,dst=by_id[e['source']],by_id[e['target']]
        style+=f'exitX={(pts[0][0]-src["x"])/src["w"]};exitY={(pts[0][1]-src["y"])/src["h"]};exitPerimeter=0;entryX={(pts[-1][0]-dst["x"])/dst["w"]};entryY={(pts[-1][1]-dst["y"])/dst["h"]};entryPerimeter=0;'
        cell=ET.SubElement(root,'mxCell',{'id':f'edge-{i}','value':'','style':style,'edge':'1','parent':'1','source':e['source'],'target':e['target']})
        geo=ET.SubElement(cell,'mxGeometry',{'relative':'1','as':'geometry'})
        ET.SubElement(geo,'mxPoint',{'x':str(pts[0][0]),'y':str(pts[0][1]),'as':'sourcePoint'})
        ET.SubElement(geo,'mxPoint',{'x':str(pts[-1][0]),'y':str(pts[-1][1]),'as':'targetPoint'})
        if len(pts)>2:
            arr=ET.SubElement(geo,'Array',{'as':'points'})
            for px,py in pts[1:-1]: ET.SubElement(arr,'mxPoint',{'x':str(px),'y':str(py)})
        if e['label']:
            cx,cy=e['at'] or ((pts[0][0]+pts[-1][0])/2,(pts[0][1]+pts[-1][1])/2)
            label_width=math.ceil(font(15).getlength(e['label']))+12
            text_cell=ET.SubElement(root,'mxCell',{'id':f'edge-label-{i}','value':e['label'],'style':f'text;html=0;align=center;verticalAlign=middle;fontFamily=Segoe UI;fontSize=15;fontColor={color};fillColor=#FFFFFF;strokeColor=none;','vertex':'1','parent':'1'})
            ET.SubElement(text_cell,'mxGeometry',{'x':str(cx-label_width/2),'y':str(cy-5),'width':str(label_width),'height':'26','as':'geometry'})
    for n in page.nodes:
        title=html.escape(n['title']).replace('\n','<br>')
        body=html.escape(n['body']).replace('\n','<br>')
        title_html=f'<b>{title}</b>' if not n['text'] or n.get('bold',False) else title
        value=f'<div style="font-family:Segoe UI;line-height:1.28">{title_html}'
        if body:value+=f'<div style="font-size:{max(n["size"]-1,15)}px;color:{C["muted"]};margin-top:6px">{body}</div>'
        value+='</div>'
        style=f'rounded=1;arcSize=12;whiteSpace=wrap;html=1;align=left;verticalAlign=top;spacingLeft=18;spacingTop=13;fontFamily=Segoe UI;fontSize={n["size"]};fontColor={n["color"]};fillColor={n["fill"]};strokeColor={n["color"]};strokeWidth=1;'
        if n['text']:style='text;html=1;whiteSpace=wrap;align=left;verticalAlign=top;spacing=0;strokeColor=none;fillColor=none;'+f'fontSize={n["size"]};fontColor={n["color"]};'
        cell=ET.SubElement(root,'mxCell',{'id':n['id'],'value':value,'style':style,'vertex':'1','parent':'1'})
        ET.SubElement(cell,'mxGeometry',{'x':str(n['x']),'y':str(n['y']),'width':str(n['w']),'height':str(n['h']),'as':'geometry'})
        if not n['group']:render_node(n)
    # Keep container backgrounds behind connectors in draw.io as well as in the preview.
    group_ids={n['id'] for n in page.nodes if n['group']}
    groups=[c for c in root if c.get('id') in group_ids]
    for cell in groups:root.remove(cell)
    for pos,cell in enumerate(groups,2):root.insert(pos,cell)
    im.save(OUT/f'page-{index:02d}.png')

# Content is maintained against the repository paths listed in docs/diagrams/README.md.
pages=[]
p=Page('01 - AWS architecture','AWS local architecture: from browser to application','customer1-aws-staging | resource prefix: customer1-staging | Floci emulates AWS; k3s runs real applications')
p.box('docker','Docker Desktop / local/compose.yml','',330,170,1540,890,'muted',fill='#F8FAFD',group=True)
p.box('vpc','AWS API resources: VPC 10.40.0.0/16','Logical AWS configuration; actual packet transport uses the Docker network.',620,225,1210,815,'blue',fill='#FFFFFF',size=17,group=True)
p.box('eks','EKS API -> real k3s container','Shared Helmfile components, deployed inside Kubernetes',1010,325,780,590,'teal',fill='#F8FCFA',size=18,group=True)
p.box('alb','Application Load Balancer','HTTP listener :80\nRouting by Host header',650,325,300,470,'blue',group=True)
p.box('browser','Browser','argocd.localhost\nkiali.localhost\nminio.localhost\nheadlamp.localhost',60,370,230,190,'muted',size=18)
p.box('mapping','Published HTTP port','127.0.0.1:80 -> floci:80',350,420,220,95,'blue',size=17)
p.edge('browser','mapping',[(290,465),(350,465)])
p.edge('mapping','alb',[(570,465),(650,465)])
for key,host,port,app,detail,y,color in [
 ('argo','argocd.localhost',30080,'Argo CD','argocd | 2 server replicas',420,'blue'),
 ('kiali','kiali.localhost',30081,'Kiali','istio-system | operator-managed',515,'purple'),
 ('minio','minio.localhost',30082,'MinIO Console','storage | S3 API on :9000',610,'teal'),
 ('headlamp','headlamp.localhost',30083,'Headlamp','headlamp | included in workflow',705,'amber')]:
    p.box('rule_'+key,host,'',670,y,260,60,color,size=18)
    p.box('svc_'+key,'NodePort Service',str(port),1040,y-5,200,75,color,size=18)
    p.box('app_'+key,app,detail,1390,y-5,370,80,color,size=17)
    p.edge('rule_'+key,'svc_'+key,[(930,y+30),(1040,y+30)],color=color)
    p.edge('svc_'+key,'app_'+key,[(1240,y+30),(1390,y+30)],'Service -> Pod',color,at=(1315,y+7))
p.box('istio','Istio','CRDs -> istiod\nNo ingress gateway installed',1040,810,330,90,'purple',size=17)
p.box('storage','MinIO','Secret -> Job -> demo bucket\nPersistence disabled (emptyDir)',1390,810,370,90,'teal',size=17)
p.box('api','AWS API :4566','Terraform / AWS CLI -> Floci',350,640,220,110,'muted',size=17)
p.box('ui','Floci UI :4500','Separate Compose service',60,660,230,95,'muted',size=17)
p.box('nexus','EC2 -> Nexus :8081','user-data installs the application',650,865,300,105,'amber',size=17)
p.box('publish','Nexus: separate HTTP path','Dynamic host port -> Floci forwarder\nGet-NexusEndpoint.ps1 resolves the URL',60,865,510,105,'amber',size=17)
p.edge('publish','nexus',[(570,915),(650,915)],color='amber')
p.text('subnets','Terraform subnets: a 10.40.1.0/24 (us-east-1a) | b 10.40.2.0/24 (us-east-1b)',650,990,1120,30,17)
p.text('note','AWS ALB forwards to NodePorts directly. Istio is not the HTTP entry point. Nexus readiness is checked after VM apply.',60,1080,1790,35,18)
p.footer(1); pages.append(p)

p=Page('02 - AWS workflows','AWS workflows: execution, readiness, and deletion','workflows/customers/customer1/aws.yaml | Headlamp is part of deployment and destruction; it is no longer a separate manual install')
p.box('entry','deploy-staging / deploy-staging-no-hook','network apply -> Kubernetes plan/apply -> Prepare-Cluster.ps1 -> Nexus plan',60,175,1800,95,'blue',size=21)
p.box('parallel','Parallel group: services','Separate Atmos processes | max_concurrency: 2 | wait_all',60,310,1800,450,'muted',size=19,group=True)
p.box('nexus','Nexus branch','Apply saved Nexus plan\nVM creation starts user-data installation',95,400,650,105,'amber',size=20)
p.box('ready','Application readiness','deploy-staging: after-apply hook\ndeploy-staging-no-hook: endpoint + HTTP steps\nGET /service/rest/v1/status/writable -> 200',95,560,650,140,'amber',size=19)
p.edge('nexus','ready',[(420,505),(420,560)],color='amber')
p.box('apps','Platform branch','istio -> argocd -> kiali -> minio -> headlamp\nThen load-balancer plan/apply',870,400,950,105,'teal',size=21)
p.box('needs','Dependencies inside components','Istio: istio-base -> istiod\nMinIO: minio -> minio-bucket (post-install/upgrade Job)\nKiali Operator reconciles the Kiali custom resource',870,560,950,140,'teal',size=19)
p.edge('apps','needs',[(1340,505),(1340,560)],color='teal')
p.edge('entry','parallel',[(960,270),(960,310)])
p.box('done','Deployment completes after both branches succeed','VM creation is not Nexus readiness. Hook retry wraps the entire kind: steps hook.',60,795,1800,85,'blue',size=20)
p.edge('parallel','done',[(960,760),(960,795)])
p.box('sequential','destroy-staging: sequential','ALB -> Kiali CR -> Headlamp -> MinIO -> Kiali Operator\n-> Argo CD -> Istio -> Kubernetes -> Nexus -> network',60,930,850,145,'purple',size=19)
p.box('destroyparallel','destroy-staging-parallel','Nexus || platform deletion (same platform order)\nNetwork is deleted only after both branches succeed.\nTerraform apply/destroy retains -auto-approve.',960,930,900,145,'purple',size=19)
p.footer(2); pages.append(p)

p=Page('03 - Files and data','Files and data: how Atmos builds a deployment','Configuration inheritance does not execute resources. Workflows supply execution order; Terraform state supplies cross-component outputs.')
p.box('atmos','atmos.yaml','Component / stack / workflow discovery\nStack name: tenant-cloud-stage',60,175,490,110,'blue',size=19)
p.box('defaults','Customer and cloud defaults','customers/customer1/_defaults.yaml\ncustomers/customer1/aws/_defaults.yaml\nExplicit import chain; nesting alone does not inherit',665,175,610,130,'blue',size=18)
p.box('catalog','stacks/catalog/','aws/, azure/, gcp/: component paths + input defaults\nhelmfile/: chart versions and shared values',60,390,660,110,'teal',size=19)
p.box('stack','Final customer stack','stacks/customers/customer1/aws/staging.yaml\nImports defaults and catalogs; overrides inputs,\nworkspace, application values, and kubeconfig',880,390,980,130,'blue',size=20)
p.edge('atmos','stack',[(550,230),(590,230),(590,335),(1370,335),(1370,390)],'discovery',at=(1400,317))
p.edge('defaults','stack',[(1275,240),(1370,240),(1370,390)])
p.edge('catalog','stack',[(720,445),(880,445)],'import',color='teal',at=(800,422))
p.box('tf','Terraform implementation','components/terraform/aws/network/\n*.tf files in one directory form one root module.\nA separate workspace holds each stack state.',60,625,660,140,'blue',size=19)
p.box('helm','Shared Helmfile implementation','components/helmfile/argocd/helmfile.yaml.gotmpl\nAdjacent values.yaml.gotmpl serializes .Values.values\nCatalog values + stack overrides -> chart values',1020,625,840,140,'teal',size=19)
p.edge('stack','tf',[(1100,520),(1100,570),(390,570),(390,625)],'resolved vars',at=(625,548))
p.edge('stack','helm',[(1510,520),(1510,625)],'state values',color='teal',at=(1600,570))
p.box('state','Terraform state and outputs','!terraform.state network subnet_ids -> AWS Kubernetes\nAzure Kubernetes reads resource_group_name and\n.subnet_ids.kubernetes from Azure network state.',60,865,790,140,'blue',size=19)
p.box('services','Kubernetes Services','Helm / operator creates Services. AWS load-balancer\nreads Argo CD, Kiali, and MinIO Console NodePorts.\nHeadlamp NodePort is passed explicitly as an input.',1020,865,840,140,'teal',size=19)
p.edge('tf','state',[(390,765),(390,865)],color='blue')
p.edge('helm','services',[(1440,765),(1440,865)],color='teal')
p.edge('state','tf',[(60,940),(30,940),(30,695),(60,695)],color='blue',dashed=True)
p.text('note','Customer2 has its own AWS manifest, workspace, and kubeconfig. Azure reuses the same Helmfile components; GCP remains an inactive template.',60,1060,1800,55,18)
p.footer(3); pages.append(p)

p=Page('04 - AWS ports and access','AWS routes, health checks, and Kubernetes permissions','Source: components/terraform/aws/load-balancer/ | Listener routing and security-group permissions are separate configuration.')
p.box('compose','local/compose.yml','Windows 127.0.0.1:80 -> floci:80',60,175,500,100,'blue',size=20)
p.box('listener','main.tf: ALB + HTTP :80','SG ingress TCP 80\nNode lookup by VPC + EKS cluster tag',670,175,600,110,'blue',size=19)
p.box('default','Default listener action','Forward unmatched hosts to Argo CD',1380,175,480,100,'muted',size=18)
p.edge('compose','listener',[(560,225),(670,225)])
p.edge('listener','default',[(1270,225),(1380,225)],color='muted')
for id,title,x,w in [('c1','FILE / RULE PRIORITY',60,510),('c2','HOST HEADER',650,330),('c3','NODE IP + NODEPORT',1080,360),('c4','HEALTH CHECK',1540,310)]: p.text(id,title,x,330,w,35,18,C['ink'],True)
rows=[('minio.tf | 1','minio.localhost','MinIO Console | 30082','/ -> 200','NodePort read from Service','teal'),('headlamp.tf | 2','headlamp.localhost','Headlamp | 30083','/ -> 200-399','var.headlamp_node_port','amber'),('argocd.tf | 5','argocd.localhost','Argo CD | 30080','/healthz -> 200','NodePort read from Service','blue'),('kiali.tf | 10','kiali.localhost','Kiali | 30081','/healthz -> 200','NodePort read from Service','purple')]
for i,(file,host,dest,health,detail,color) in enumerate(rows):
    y=400+i*125
    p.box('f'+str(i),file,detail,60,y,510,95,color,size=18)
    p.box('h'+str(i),host,'condition: host_header',650,y,330,95,color,size=18)
    p.box('t'+str(i),dest,'target_type: ip',1080,y,360,95,color,size=18)
    p.box('p'+str(i),health,'HTTP health check',1540,y,310,95,color,size=18)
    p.edge('f'+str(i),'h'+str(i),[(570,y+47),(650,y+47)],color=color)
    p.edge('h'+str(i),'t'+str(i),[(980,y+47),(1080,y+47)],color=color)
    p.edge('t'+str(i),'p'+str(i),[(1440,y+47),(1540,y+47)],color=color,dashed=True)
p.box('sg','Target groups and network access','Each route file configures SG egress to its NodePort\nand attaches the EKS node IP to its target group.\nThe provider uses the stack-specific kubeconfig_path.',60,950,860,140,'blue',size=19)
p.box('rbac','Credentials and RBAC','MinIO Secret rootUser/rootPassword -> bucket Job.\nHeadlamp ServiceAccount: view + Secret read in storage.\nA token identifies the caller; RBAC grants permissions.\nMinIO persistence is disabled in the lab catalog.',980,950,880,155,'teal',size=19)
p.footer(4); pages.append(p)

p=Page('05 - Azure local environment','Azure local environment: provisioning and application access','customer1-azure-staging | real k3s workloads via Floci Azure | the Azure load balancer stores configuration but does not forward traffic')
p.box('start','Start-AzureLocal.ps1','local/compose.azure.yml -> Floci Azure API :4577\nPinned nightly digest; TLS CA trusted for current user\nDocker socket lets the emulator create a k3s node.',60,175,840,135,'blue',size=20)
p.box('deploy','Customer Azure workflow','workflows/customers/customer1/azure.yaml\nnetwork -> kubernetes -> access -> istio -> argocd\n-> kiali -> minio -> headlamp -> load-balancer',1020,175,840,135,'blue',size=20)
p.box('prepare','Prepare-AzureCluster.ps1','Read selected Atmos configuration -> request admin kubeconfig\nResolve published API port from the matching Docker container\nWrite .local-runtime/kubeconfig-customer1-azure-staging.yaml\nWait for Ready node and CoreDNS; current API port: 6600.',60,390,1800,155,'teal',size=20)
p.edge('start','prepare',[(480,310),(480,390)],'API prerequisite',at=(570,345))
p.edge('deploy','prepare',[(1440,310),(1440,390)],'access step',at=(1510,345))
p.box('browser','Browser / Windows','Argo CD: localhost:18080\nKiali: localhost:18081',60,625,450,110,'muted',size=20)
p.box('pf','kubectl port-forward','Argo CD svc/argocd-server 18080:80\nKiali svc/kiali 18081:20001\nRun each command in its own terminal.',630,615,610,135,'teal',size=19)
p.box('pods','Real Kubernetes workloads','API -> Service-selected Pod\nArgo CD and Kiali returned HTTP 200.\nIstio, MinIO, Headlamp also deployed.',1360,615,500,135,'teal',size=19)
p.edge('browser','pf',[(510,680),(630,680)],color='teal')
p.edge('pf','pods',[(1240,680),(1360,680)],color='teal')
p.box('lb','Azure load-balancer: API resources only','Public IP + LB + backend pool/address + probe + TCP rule\nRule: frontend :80 -> Kiali NodePort :30081\nBackend IP is recorded in the stack; recheck after recreation.\nNo packet forwarding is implemented by this Floci service.',60,825,900,175,'amber',size=19)
p.box('limits','Current emulator constraints','AKS read-back omits properties: repeat plans may replace it.\nReview plans before repeating Kubernetes apply.\nLocal subnet RBAC assignment is disabled in this stack.\nThe real-Azure module defaults still enable the assignment.',1020,825,840,175,'amber',size=19)
p.text('destroy','destroy-staging: load-balancer -> Kiali CR -> headlamp -> minio -> kiali -> argocd -> istio -> kubernetes -> network',60,1050,1800,35,18)
p.text('stop','Delete resources successfully before Compose stop. KEEP_RUNNING_ON_SHUTDOWN preserves AKS during emulator restarts.',60,1090,1800,30,17)
p.footer(5); pages.append(p)


def wrap_line(line, width, size, bold):
    result=[]
    while line and font(size,bold).getlength(line)>width:
        cut=len(line)
        while cut>0 and font(size,bold).getlength(line[:cut])>width: cut-=1
        assert cut>0
        space=line.rfind(' ',0,cut+1)
        if space>cut//2: cut=space
        result.append(line[:cut].rstrip())
        line=line[cut:].lstrip()
    return result+[line]


def validate_and_wrap(page):
    ids={n['id'] for n in page.nodes}
    assert len(ids)==len(page.nodes), page.name
    for n in page.nodes:
        assert 0<=n['x'] and 0<=n['y'] and n['x']+n['w']<=W and n['y']+n['h']<=H,n['id']
        for field,bold in [('title',not n['text'] or n.get('bold',False)),('body',False)]:
            size=n['size'] if field=='title' else max(n['size']-1,15)
            width=n['w']-(0 if n['text'] else 36)
            n[field]='\n'.join(piece for line in n[field].split('\n') for piece in wrap_line(line,width,size,bold))
        title_h=len(n['title'].split('\n'))*(n['size']+7)
        body_h=(3+len(n['body'].split('\n'))*(n['size']+7)) if n['body'] else 0
        required=(2 if n['text'] else 13)+title_h+body_h
        assert required<=n['h'],(page.name,n['id'],'text exceeds height',required,n['h'])
    for e in page.edges: assert e['source'] in ids and e['target'] in ids


if __name__ == '__main__':
    mx=ET.Element('mxfile',{'host':'app.diagrams.net','agent':'Qubership architecture generator','type':'device','pages':str(len(pages))})
    for i,p in enumerate(pages,1):
        validate_and_wrap(p)
        export(p,i,mx)
    ET.indent(mx)
    ET.ElementTree(mx).write(OUT/'atmos-local-demo.drawio',encoding='utf-8',xml_declaration=True)
    print(f'Created {len(pages)} editable pages and matching PNG previews in {OUT}')
