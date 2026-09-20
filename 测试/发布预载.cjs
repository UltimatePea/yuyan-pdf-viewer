// 文言：以发布之 V8 与包内资源验之。汉语：NODE_OPTIONS 预载，在实际发布可执行文件中运行回归。
const script=process.env.YY_VIEWER_TEST_SCRIPT;
delete process.env.NODE_OPTIONS;
delete process.env.YY_VIEWER_TEST_SCRIPT;
require(script);
process.exit(process.exitCode||0);
