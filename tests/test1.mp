prologues := 3;
outputtemplate := "%j-%c.svg";
outputformat := "svg";
verbatimtex
\documentclass{article}
\usepackage{mathpazo}
\begin{document}
etex
beginfig(1);
h=5cm; w=8cm; theta=60;
xlength=1.7;
ylength=1.3;
pair temp[]; pair w[]; picture lab[];
z0=(0,0); z1=dir 0 scaled h/2; z2=dir theta scaled h/2;
w1= xlength*z1; w2= ylength*z2; w3= w1+w2;
draw -xlength*z1--2*xlength*z1;
temp1=(0,ylength*y2);
draw -xlength*z1+temp1--2*xlength*z1+temp1;
draw -ylength*z2--2*ylength*z2;
temp2=(xlength*x1,0);
draw -ylength*z2+temp2--2*ylength*z2+temp2;
drawarrow z0--z1 withpen pencircle scaled 2bp;
drawarrow z0--z2 withpen pencircle scaled 2bp;
drawarrow z0--w3 withpen pencircle scaled 2bp withcolor red;
draw z0 withpen pencircle scaled 4bp; draw w1 withpen pencircle scaled 4bp;
draw w2 withpen pencircle scaled 4bp; draw w3 withpen pencircle scaled 4bp;
label.llft(btex $(0,0)\,\,$ etex, z0);
label.lrt (btex $(x^1,0)$ etex, w1);
label.ulft(btex $(0,x^2)$ etex, w2);
label.urt (btex $\,\,(x^1,x^2)$ etex, w3);
label.lrt (btex head etex, w3);
label.lrt (btex $\!\!$tail etex, z0);
label.ulft(btex $P$ etex, w3);
label.bot (btex $(1,0)$ etex, z1);
label.lft (btex $(0,1)$ etex, z2);
label.urt (btex $x^1$ axis etex, 1.4 w1);
label.rt  (btex $x^2$ axis etex, 1.4 w2);
xx=h/2*xlength; yy=h/2*ylength;
clip currentpicture to (-xx/3,-yy/3)--(-xx/3,4/3yy)--(5.1/3xx,4/3yy)--(5.1/3xx,-yy/3)--cycle;
endfig;
end
