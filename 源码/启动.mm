// 文言：原生入口载 V8，豫言主程序行其事。汉语：在应用进程内嵌入 Node/V8，保持正常 macOS bundle 身份。
#import <Foundation/Foundation.h>
#include <node.h>
#include <vector>
#include <string>
int main(int argc,char **argv){@autoreleasepool {
    NSString *script=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"宿主.cjs"];
    std::vector<std::string> values={argv[0],script.UTF8String};for(int i=1;i<argc;i++)values.emplace_back(argv[i]);
    std::vector<char *> args;for(auto &s:values)args.push_back(s.data());args.push_back(nullptr);
    return node::Start((int)values.size(),args.data());
}}
