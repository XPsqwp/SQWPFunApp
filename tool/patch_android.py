import re, pathlib

gradle = pathlib.Path('android/app/build.gradle.kts')
s = gradle.read_text()

# 1) 固定签名配置（keystore/sqwp.jks 随仓库提交，密码是个人构建用的）
signing = '''
    signingConfigs {
        create("sqwp") {
            storeFile = file("sqwp.jks")
            storePassword = "sqwp123"
            keyAlias = "sqwp"
            keyPassword = "sqwp123"
        }
    }
'''
if 'signingConfigs {' not in s:
    s = s.replace('android {', 'android {' + signing, 1)

# 2) release 用固定 key，而不是每次 CI 随机生成的 debug key
s = s.replace('signingConfig = signingConfigs.getByName("debug")',
              'signingConfig = signingConfigs.getByName("sqwp")')

# 3) INTERNET 权限 + 明文流量
man = pathlib.Path('android/app/src/main/AndroidManifest.xml')
m = man.read_text()
if 'android.permission.INTERNET' not in m:
    m = m.replace('<application', '<uses-permission android:name="android.permission.INTERNET"/>\n    <application', 1)
m = m.replace('<application', '<application android:usesCleartextTraffic="true"', 1)
m = m.replace('android:label="sqwpfun"', 'android:label="SQWPFun"')
man.write_text(m)

gradle.write_text(s)
print('patched gradle + manifest')
