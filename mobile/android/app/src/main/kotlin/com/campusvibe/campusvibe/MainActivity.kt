package com.campusvibe.campusvibe

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var saving: ByteArray? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "campusvibe/files").setMethodCallHandler { call,result ->
            if(call.method !in listOf("pick","pickPhoto","save")) { result.notImplemented();return@setMethodCallHandler }
            if(pending!=null){result.error("busy","Finish current file selection",null);return@setMethodCallHandler}
            val picking=call.method!="save"
            val intent=Intent(if(picking)Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT)
            intent.addCategory(Intent.CATEGORY_OPENABLE)
            if(picking){ intent.type="*/*";intent.putExtra(Intent.EXTRA_MIME_TYPES,if(call.method=="pickPhoto") arrayOf("image/jpeg","image/png") else arrayOf("image/jpeg","image/png","application/pdf")) }
            else {intent.type=call.argument<String>("mime");intent.putExtra(Intent.EXTRA_TITLE,if(intent.type=="application/pdf") "CampusVibe-notes.pdf" else "CampusVibe-image.jpg");saving=call.argument<ByteArray>("bytes")}
            pending=result
            try{ startActivityForResult(intent,if(picking) 701 else 702) }
            catch(e:Exception){pending=null;saving=null;result.error("picker",e.message,null)}
        }
    }
    @Deprecated("Flutter activity callback")
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode !in 701..702)return
        val callback=pending?:return
        val bytes=saving
        saving=null;pending=null
        val uri=data?.data
        if(resultCode!=RESULT_OK||uri==null){callback.success(null);return}
        Thread {
            try{
                val value=if(requestCode==701)contentResolver.openInputStream(uri)!!.use { stream ->
                    val out=ByteArrayOutputStream()
                    val buffer=ByteArray(8192)
                    while(true){val n=stream.read(buffer);if(n<0)break;if(out.size()+n>4194304)throw IllegalArgumentException("File exceeds 4 MB");out.write(buffer,0,n)}
                    out.toByteArray()
                }else{contentResolver.openOutputStream(uri)!!.use{it.write(requireNotNull(bytes))};null}
                runOnUiThread {callback.success(value)}
            }catch(e:Exception){runOnUiThread {callback.error("file",e.message,null)}}
        }.start()
    }
}
