from django.urls import path
from . import views

urlpatterns = [
    path('hotspots/', views.HotspotListView.as_view(), name='hotspot_list'),
    path('generate-hotspot/', views.HotspotAddView.as_view(), name='generate_hotspot'),
    path('delete-hotspot/<int:pk>/', views.HotspotDeleteView.as_view(), name='hotspot_delete'),

    path('create-hotspot-api/', views.create_hotspot_api, name='create_hotspot_api'),
    path('get_products/', views.get_products, name='get_products'),
]
