import 'package:flutter/material.dart';

const violet = Color(0xff693875);
ThemeData campusTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final scheme = ColorScheme.fromSeed(seedColor: violet, brightness: brightness);
  final surface = light ? const Color(0xfffff9fc) : scheme.surface;
  final outline = light ? const Color(0xffe6d9e7) : scheme.outlineVariant;
  final border = OutlineInputBorder(borderRadius: BorderRadius.circular(13),borderSide:BorderSide(color:outline));
  return ThemeData(useMaterial3:true,brightness:brightness,colorScheme:scheme,scaffoldBackgroundColor:surface,
    appBarTheme:AppBarTheme(backgroundColor:surface,elevation:0,scrolledUnderElevation:0,
      titleTextStyle:TextStyle(color:scheme.onSurface,fontWeight:FontWeight.w800,fontSize:24)),
    cardTheme:CardThemeData(color:light?Colors.white:scheme.surfaceContainerLow,elevation:0,
      shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(17),side:BorderSide(color:outline))),
    inputDecorationTheme:InputDecorationTheme(filled:true,fillColor:light?Colors.white:scheme.surfaceContainerLow,
      border:border,enabledBorder:border,focusedBorder:border.copyWith(borderSide:BorderSide(color:scheme.primary,width:1.6))),
    filledButtonTheme:FilledButtonThemeData(style:FilledButton.styleFrom(minimumSize:const Size(48,46),
      shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(18)))),
    navigationBarTheme:NavigationBarThemeData(height:68,backgroundColor:surface,indicatorColor:scheme.secondaryContainer,
      labelTextStyle:const WidgetStatePropertyAll(TextStyle(fontSize:11,fontWeight:FontWeight.w600))),
    tabBarTheme:TabBarThemeData(indicatorSize:TabBarIndicatorSize.tab,dividerHeight:0,
      indicator:BoxDecoration(color:violet,borderRadius:BorderRadius.circular(32)),labelColor:Colors.white,
      unselectedLabelColor:scheme.onSurface,labelStyle:const TextStyle(fontSize:13,fontWeight:FontWeight.w700)));
}

class SearchableCampusList extends StatefulWidget {
  const SearchableCampusList({super.key,required this.rows,required this.hint,required this.fields,
    required this.item,required this.empty,this.action,this.filters=const [],this.matches});
  final List rows;
  final String hint,empty;
  final List<String> fields,filters;
  final bool Function(dynamic,String)? matches;
  final Widget Function(dynamic) item;
  final Widget? action;
  @override
  State<SearchableCampusList> createState()=>_SearchableCampusListState();
}
class _SearchableCampusListState extends State<SearchableCampusList>{
  String query='',filter='All';
  @override
  Widget build(BuildContext context){
    final rows=widget.rows.where((r)=>widget.fields.any((f)=>(r[f]??'').toString().toLowerCase().contains(query)) &&
      (filter=='All'||widget.matches?.call(r,filter)==true)).toList();
    return Column(children:[
      TextField(onChanged:(s)=>setState(()=>query=s.trim().toLowerCase()),decoration:InputDecoration(
        prefixIcon:const Icon(Icons.search),hintText:widget.hint,isDense:true)),
      if(widget.filters.isNotEmpty) Align(alignment:Alignment.centerLeft,child:SingleChildScrollView(scrollDirection:Axis.horizontal,
        child:Row(children:[for(final label in ['All',...widget.filters]) Padding(padding:const EdgeInsets.only(right:6),
          child:ChoiceChip(label:Text(label),selected:filter==label,showCheckmark:false,onSelected:(_)=>setState(()=>filter=label)))]))),
      Expanded(child:rows.isEmpty?Center(child:Text(query.isEmpty && filter=='All'?widget.empty:'No matching results',textAlign:TextAlign.center)):
        ListView.builder(itemCount:rows.length,itemBuilder:(_,i)=>widget.item(rows[i]))),
      if(widget.action!=null)Align(alignment:Alignment.centerRight,child:widget.action!)
    ]);
  }
}
