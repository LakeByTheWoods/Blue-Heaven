#version 330
uniform vec4 rect_color;
out vec3 color;
void main(){
 color=rect_color.rgb;
}
