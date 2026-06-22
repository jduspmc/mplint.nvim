prologues := 3;
outputtemplate := "%j-%c.svg";
outputformat := "svg";
verbatimtex
\documentclass{article}
\usepackage{mathpazo}
\begin{document}
etex
vardef draw_star(expr c, r, n)(expr smooth) =
save p, angle_step;
path p;
numeric angle_step;
angle_step := 360 / n;
for i = 0 upto n:
if i = 0:
p := c + (r * cosd(0), r * sind(0));
else:
if smooth:
p := p .. (c + (r * cosd(i * angle_step), r * sind(i * angle_step)));
else:
p := p -- (c + (r * cosd(i * angle_step), r * sind(i * angle_step)));
fi;
fi;
endfor;
p := p -- cycle;
draw p withpen pencircle scaled 1bp;
enddef;
beginfig(1);
draw_star((0,0), 50, 5, false);
endfig;
beginfig(2);
draw_star((120,0), 50, 6, true);
endfig;
end;
