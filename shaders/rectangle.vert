#version 330
uniform vec4 rect;
uniform vec2 screen_size;
void main(){
  if(gl_VertexID==0)gl_Position.xy=rect.xy;
  if(gl_VertexID==1)gl_Position.xy=rect.xw;
  if(gl_VertexID==2)gl_Position.xy=rect.zy;
  if(gl_VertexID==3)gl_Position.xy=rect.zw;
  gl_Position.zw=vec2(-1.0,1.0);
  gl_Position.xy=gl_Position.xy/screen_size*vec2(2.0,-2.0)-vec2(1.0,-1.0);
}
