prologues := 3;
outputtemplate := "%j%c.svg";
outputformat := "svg";
verbatimtex
\documentclass{article}
\usepackage{mathpazo}
\usepackage{xcolor}
\begin{document}
etex
beginfig(1);
path r, k;
r = for t = 1 upto 360: cosd 2t * dir t .. endfor cycle;
r := r scaled 150;
k = for t = 1 upto 360: point 29t of r -- endfor cycle;
draw k dashed withdots scaled 1/8
withpen pencircle scaled 1/4
withcolor 1/2[blue, white];
draw r withcolor 2/3 red;
path xx, yy;
xx = (left -- right) scaled 160;
yy = (down -- up) scaled 160;
drawarrow xx; label.rt(btex $\displaystyle x$ etex scaled 2, point 1 of xx);
drawarrow yy; label.top(btex  $\displaystyle y$ etex scaled 2, point 1 of yy);
endfig;
end;
